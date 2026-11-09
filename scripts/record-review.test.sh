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

# ⛔ THE RECORDER RESOLVES `brief-gate.sh` FOR THE NON-VACUITY ARM (agent-infra#3442) AND THIS SUITE
# MUST NOT INHERIT WHERE IT LOOKS. The chain is `$SELF`-adjacent, `$AGENT_INFRA_PATH/scripts/
# orchestrator-harness`, `~/.pi/agent/scripts`; most arms here drive a MUTANT COPY under `$T` (no
# sibling gate) with a private `$HOME`, so the rung that answers is the AMBIENT one — and on a box whose
# `$AGENT_INFRA_PATH` or installed copy is one generation behind, that gate answers 78 for the new verb
# and the recorder correctly REFUSES. Measured: six arms whose subject is the diff digest, the 402 cap
# or the carry went red on exactly that, from box state rather than from the code under test — the same
# "a fixture that inherits ambient env cannot make a claim about isolation" defect this suite already
# fixed once. Pinning the root to THIS tree is the isolation. It SUPPLIES a resolution root rather than
# opening a gate (the `spawn-gate.test.sh` rule): the fail-closed case is still pinned, by 13v4's
# stale-validator arm, which wins on the `$SELF`-adjacent rung ABOVE this one.
#
# ⛔ NOT `export VAR="$(…)"` (the #2569 shape, and the same fix `install-launchd.test.sh` carries).
# A DECLARATION builtin's exit status is the BUILTIN's, not the substitution's, so `$?` does not
# report a `cd` that failed — the shape hides it, which is why `scripts/check-false-pass-shapes.sh`
# bans it (`discarded-status`, and this line was the ONE finding that red reported on main: #2741).
# A bare assignment carries the substitution's status, so the `||` is a real check: a root that
# cannot be resolved stops the suite loudly instead of being pinned to whatever `pwd` managed to
# print. Stated so it is not read as more than it is: `SCRIPT_DIR` is already resolved the same way
# higher up under `set -euo pipefail`, so an empty `SCRIPT_DIR` is not reachable here and an empty
# operand would in any case resolve to `/` rather than fail. This arm is therefore the banned-shape
# repair plus defence in depth — not the only thing between the arms below and the ambient rung.
AGENT_INFRA_PATH="$(cd "$SCRIPT_DIR/.." && pwd)" || {
    echo "record-review.test.sh: cannot resolve the checkout root from SCRIPT_DIR='$SCRIPT_DIR'" >&2
    exit 1
}
export AGENT_INFRA_PATH

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
#   comments (… /issues/<n>/comments) → the DURABLE comment channel (#3168):
#                                   READ (--paginate … --jq) prints
#                                   ${STUB_COMMENT_BODIES:-} verbatim, or — when
#                                   the ENVELOPE fixture ${STUB_COMMENT_JSON:-} is
#                                   set — applies the caller's OWN --jq
#                                   expression to it with the real `jq` (so the
#                                   recorder's frame expression — the delimiter
#                                   strip and the record terminator — is EXECUTED,
#                                   not merely present in the source), or a
#                                   NON-EMPTY error body on STDOUT with exit 1
#                                   when STUB_COMMENT_FAIL=1 (the `gh api`
#                                   shape that must never be read as "no
#                                   comment"); POST (-X POST … --input -)
#                                   captures stdin to ${STUB_COMMENT_CAPTURE:-}
#                                   and exits 1 when STUB_COMMENT_POST_FAIL=1
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
    #   STUB_COMMENT_POST_FAIL=1 → the POST is refused (the 403 / spent-token arm).
    #                           ⛔ MODELLED IN THIS ARM TOO (#3168 merge resolution):
    #                           the producer reads with `--jq`, so THIS is the arm a
    #                           real run hits both for the read and for the write. A
    #                           stub that only failed the POST in the other arm left
    #                           the failure path unreachable and its vector green.
    #   STUB_COMMENT_CAPTURE  → sink for a POST body, so the suite can assert the
    #                           COMMENT really carries the marker.
    # ⛔ ONE ARM, BOTH READS (#3168 re-review P2). This arm was previously followed by
    # a SECOND `…/issues/<n>/comments` arm carrying the ENVELOPE / FAILURE / BODIES
    # behaviour. The two matched the SAME regex and THIS one `exit 0`s in every branch,
    # so the second was UNREACHABLE: `STUB_COMMENT_JSON`, `STUB_COMMENT_FAIL` and
    # `STUB_COMMENT_BODIES` were inert knobs the header above advertised as live, and a
    # later author following that header would have written a vector testing nothing
    # (measured: driving the stub with an envelope printed the raw `STUB_COMMENTS`
    # frame and the caller's `--jq` was never applied). Folded in HERE, so there is one
    # read path and no arm can shadow another again.
    # ⛔ NARROW: `…/issues/<n>/comments` is the PR's comment LIST; `…/issues/comments/<id>`
    # is the SINGLE-comment read used by `--evidence comment:<id>` and must keep
    # falling through to the generic tail. An unanchored `/comments` match swallowed
    # the evidence read and reddened §13h.
    if grep -qE -- "/issues/[0-9]+/comments" <<<"$*"; then
        if grep -qF -- "--jq" <<<"$*"; then
            [ "${STUB_COMMENTS_FAIL:-0}" = "1" ] && exit 1
            # ⛔ THE FAILURE ARM IS THE LOAD-BEARING ONE: `gh api` writes a NON-EMPTY
            # JSON error body to STDOUT *and* exits non-zero, so a producer that
            # captured stdout without testing the exit status would read
            # `{"message": "API rate limit exceeded"}` as comment text and could
            # conclude the marker is already posted when it is not.
            if [ "${STUB_COMMENT_FAIL:-0}" = "1" ]; then
                printf '%s\n' '{"message":"API rate limit exceeded","status":"403"}'
                exit 1
            fi
            # ⛔ MODEL --jq, DO NOT IGNORE IT. When a JSON ENVELOPE fixture is supplied,
            # apply the CALLER'S OWN expression to it with the real jq — the same shape
            # real `gh` has. Without this the recorder's frame expression (the
            # `gsub("[…]"; "")` delimiter strip and the `\u001e` record terminator —
            # `git show bd1b205d:scripts/record-review.sh | grep -nF 'gsub("[\u001e\u001f]"; "")'` → :2386; head
            # `grep -nF 'gsub("[\u001e\u001f]"; "")' scripts/record-review.sh` → :2445) is executed by NO vector at
            # all: every
            # other fixture supplies the frame PRE-BUILT through $STUB_COMMENTS, so
            # deleting either half of the expression left the suite GREEN. §14.1d(b4)
            # is the vector that now reddens when the strip is removed.
            if [ -n "${STUB_COMMENT_JSON:-}" ]; then
                _cjq="" _cprev=""
                for _carg in "$@"; do
                    if [ "$_cprev" = "--jq" ]; then _cjq="$_carg"; break; fi
                    _cprev="$_carg"
                done
                if [ -n "$_cjq" ]; then
                    jq -r "$_cjq" <<<"$STUB_COMMENT_JSON" || exit 1
                    exit 0
                fi
            fi
            if [ -n "${STUB_COMMENT_BODIES:-}" ]; then
                printf '%s\n' "${STUB_COMMENT_BODIES}"
                exit 0
            fi
            printf '%s' "${STUB_COMMENTS:-}"
            exit 0
        fi
        [ "${STUB_COMMENT_POST_FAIL:-0}" = "1" ] && exit 1
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
        # #3440: PER-SHA rows, so ONE invocation can model a head whose surface differs
        # from its base — the shape base-attribution is decided on, and the only way to
        # tell "the PR caused this red" from "the base already had it" in one run.
        # Inert unless a vector sets the dir (every pre-existing vector falls through to
        # the plain STUB_CHECKS_ROWS arm below, unchanged).
        if [ -n "${STUB_CHECKS_ROWS_DIR:-}" ]; then
            cs_sha="$(printf '%s' "$*" | sed -n 's#.*/commits/\([0-9a-f]*\)/check-runs.*#\1#p')"
            if [ -n "$cs_sha" ] && [ -f "${STUB_CHECKS_ROWS_DIR}/$cs_sha" ]; then
                cat "${STUB_CHECKS_ROWS_DIR}/$cs_sha"; exit 0
            fi
            exit 0
        fi
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
    # DELTA EVIDENCE (§20): the base the range is classified against — the API's
    # OWN declaration, in one read. Set-but-empty is meaningful: an EMPTY answer
    # models "the base could not be read", which the delta arm must REFUSE rather
    # than assume.
    if [ -n "${STUB_BASE_PAIR+x}" ] && grep -qF -- "[.base.sha,.base.ref]" <<<"$*"; then
        [ "${STUB_BASE_PAIR_FAIL:-0}" = "1" ] && exit 1
        printf '%s\t%s\n' "${STUB_BASE_SHA:-}" "${STUB_BASE_REF:-main}"
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
        # ⛔ THE DEFAULT BODY CARRIES THE #3442 MUTATION-ATTRIBUTION BLOCK, AND THAT IS A FIXTURE
        # CONTRACT CHANGE, NOT A FICTURE THAT WAS TUNED TO STAY GREEN. Before agent-infra#3442 a
        # `clean` record could name ANY artifact, so "Reviewed the diff; no issues found." was
        # sufficient; the contract now requires the artifact to say WHICH mutant reddens WHICH row,
        # and an arm about the STATE/parent/postdate machinery must not be refused by the arm about
        # non-vacuity (it would then be green for a reason unrelated to what it pins — the
        # unrelated-row trap #3442 itself names). `unset` vs `empty` still differs: only an UNset
        # STUB_EVIDENCE_BODY gets the block, because an explicitly EMPTY body is its own adversarial
        # vector (§13q2) and must stay expressible.
        if [ -z "${STUB_EVIDENCE_BODY+x}" ]; then
            _body="Reviewed the diff; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| test.sh:12 the gate refuses an empty brief | sed s/rc=80/rc=0/ x.sh | section A (i) | rc=0, wanted 80 |
"
        else
            _body="$STUB_EVIDENCE_BODY"
        fi
        printf '%s\t%s\t%s%s\n' \
            "${STUB_EVIDENCE_AT:-2026-01-02T03:04:05Z}" \
            "$_parent" \
            "$(printf '%s' "$_body" | awk '{ gsub(/\\/,"\\\\"); gsub(/\t/,"\\t"); printf "%s\\n", $0 }')" \
            "$_state"
        exit 0
    fi
    if grep -qF -- "commits/" <<<"$*" && [ -n "${STUB_COMMIT_DATES_DIR:-}" ]; then
        # DELTA EVIDENCE (§20): a PER-SHA commit date. The delta's covering-verdict
        # anchor is the newest AUTHORED commit in the range, which is a different
        # commit from the head — with one global date the two anchors are
        # indistinguishable and the anchor arm could not be pinned at all.
        _cs="$(printf '%s' "$*" | sed -n 's#.*commits/\([0-9a-f]\{40\}\).*#\1#p')"
        if [ -n "$_cs" ] && [ -f "${STUB_COMMIT_DATES_DIR}/$_cs" ]; then
            cat "${STUB_COMMIT_DATES_DIR}/$_cs"
            exit 0
        fi
    fi
    if grep -qF -- "commits/" <<<"$*" ; then
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
# ⛔ THE BOX-GLOBAL ATTRIBUTES FILE THE 20i6/M38 CELLS PLANT IS `$F_HOME/.config/git/attributes`, and git
# reads that path ONLY when `XDG_CONFIG_HOME` is unset (or empty): with it set, git reads
# `$XDG_CONFIG_HOME/git/attributes` instead, the planted `merge=union` rule is INVISIBLE, the fixture's
# merge conflicts again, and M38's mutant is refused by the very anchor the shipped recorder is — so the
# cell reports ITSELF vacuous and the vector certifies nothing. That is the same defect this file already
# fixed twice (see the AGENT_INFRA_PATH pin and the AI_REVIEW_GATE_KEY pin below): a fixture that
# inherits ambient env cannot make a claim about isolation. MEASURED, and it is the whole of CI's red
# `bash-suites` shard here: on a caller with `XDG_CONFIG_HOME` set this suite is `PASS=1415 FAIL=2` with
# M38 the ONLY red (rc 3, "mutant still refused — the vector is vacuous"); on the identical tree with
# `XDG_CONFIG_HOME` unset it is `PASS=1417 FAIL=0`. Pinning it to the FAKE home makes the fixture's own
# file the one git reads, whatever the caller has — git still falls back to `<HOME>/.config` for an
# EMPTY value, so the 20i6 control (`XDG_CONFIG_HOME=`), which deliberately asserts the un-neutralised
# read IS steered, keeps measuring exactly what it did before.
export XDG_CONFIG_HOME="$F_HOME/.config"
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
# ⛔ AND IT MUST PARSE, WITH ITS SLOTS ALIGNED. The record printf has TWO branches
# (repo / no-repo) whose slot counts differ, and the no-repo branch is reachable in
# production — a lane with no repo context mints here. "a file exists and it has no
# repo key" is satisfied by a record whose fields have SHIFTED one slot: MEASURED, in
# review of this merge, by dropping `"$DELTA_FIELDS"` from the no-repo argument list —
# BOTH suites stayed green while the minted record did not parse, which is the #3400
# "an unparseable record is NO RECORD" shape arriving on a successful exit. Asserting
# the parse is what makes the slot count actually covered rather than counted by eye.
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["verdict"]=="clean-micro", d.get("verdict"); assert d["pr"]==424244, d.get("pr"); assert "head_sha" in d' "$L" 2>/dev/null \
    && ok "repo-less record PARSES with verdict/pr slots aligned (no-repo printf branch covered)" \
    || bad "repo-less record is MALFORMED or misaligned: $(cat "$L" 2>/dev/null)"

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
# ⛔ THE FIXTURE SPEAKS THE FRAME THE GATE ADMITS (review finding 2): the read asks
# for `"<author_association>\u001f<body>"` and the "already present" test requires a
# TRUSTED association AND the body equal to the marker. The old fixture handed a
# bare body, which is why a plain line-grep looked correct.
Q1224D="$T/p1224-comment-2.json"; : > "$Q1224D"
STUB_COMMENTS="OWNER"$'\037'"$(cat "$Q1224C_BODY")"$'\036' STUB_COMMENT_CAPTURE="$Q1224D" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224D" ]; then
    bad "#1224 a re-run DUPLICATED the evidence comment (the marker was already there) — every re-record would bury the timeline"
else
    ok "#1224 a re-run posts NO second comment when the marker is already present (idempotent, like the body append)"
fi
# ⛔ NEGATIVE CONTROL 1 — AN UNATTESTED AUTHOR IS NOT "ALREADY PRESENT". On a public
# repo the marker is visible in the PR body, so ANY account can paste it; treating
# that as delivered would (a) skip the producer's own post forever and (b) let an
# unprivileged account suppress the only evidence channel CI can read. Reverting the
# association test reddens THIS vector and leaves the idempotency one green.
Q1224F="$T/p1224-comment-4.json"; : > "$Q1224F"
STUB_COMMENTS="NONE"$'\037'"$(cat "$Q1224C_BODY")"$'\036' STUB_COMMENT_CAPTURE="$Q1224F" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224F" ]; then
    ok "#1224 a marker pasted by an UNATTESTED account does not count as delivered — the producer posts its own copy"
else
    bad "#1224 an unattested commenter's pasted marker SUPPRESSED the producer's post — any account could silence the evidence channel, and the run would report it delivered (finding 2)"
fi
# ⛔ NEGATIVE CONTROL 2 — A QUOTING COMMENT IS NOT "ALREADY PRESENT". The gate
# requires the marker to be the comment's WHOLE body; a multi-line comment that
# merely CONTAINS the marker line is REFUSED by the gate, so honouring it here would
# report delivery for an artifact the gate throws away.
Q1224G="$T/p1224-comment-5.json"; : > "$Q1224G"
STUB_COMMENTS="OWNER"$'\037'"Here is the attestation I saw:
$(cat "$Q1224C_BODY")
— a reviewer quoting it"$'\036' STUB_COMMENT_CAPTURE="$Q1224G" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224G" ]; then
    ok "#1224 a QUOTING comment does not count as delivered — the whole-body rule matches the gate"
else
    bad "#1224 a comment that merely QUOTED the marker suppressed the producer's post — the producer would report delivery for an artifact the gate refuses (finding 2)"
fi
# ⛔ NEGATIVE CONTROL 3 — A MARKER AS THE FIRST LINE WITH TEXT BENEATH IT (review
# round 3 finding 1a). This is the shape that fooled the LINE-based reader: line 1
# is "OWNER\x1f<marker>", so `$1 == OWNER` and `body == marker` both held, the
# producer skipped its own post and reported DELIVERED — while the gate requires the
# marker to be the WHOLE body and refuses that comment. This is a human paste, not
# an attack, and the producer's comment was never posted again.
Q1224J="$T/p1224-comment-9.json"; : > "$Q1224J"
STUB_COMMENTS="OWNER"$'\037'"$(cat "$Q1224C_BODY")"$'\n'"One line of context under it"$'\036' STUB_COMMENT_CAPTURE="$Q1224J" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224J" ]; then
    ok "#1224 a comment whose FIRST LINE is the marker but which continues beneath it does NOT count as delivered — the whole-body rule is what the gate applies"
else
    bad "#1224 a marker with a note under it suppressed the producer's post — the comment is not the artifact the gate admits, so the evidence was never delivered (finding 1a)"
fi
# ⛔ THE DELIMITER STRIP IS A SOURCE-LEVEL CONTRACT, so it is pinned at the source
# (review round 3 finding 1b). A behavioural vector cannot see it: the `gh` stub
# returns the ALREADY-JQ'd frame, so a producer that forgot the `gsub` would be fed
# a frame it never produced. The gate strips 0x1e/0x1f from every comment body
# before framing (its REVIEW_COMMENTS_JQ, pinned by the gate's own 1224T), so a
# comment body can never manufacture a second record. Without the strip HERE an
# unattested account could satisfy the producer's dedup and suppress its post.
Q14STRIP="$(grep -c 'gsub("\[\\u001e\\u001f\]"; "")' "$RECORD" 2>/dev/null || echo 0)"
Q14TERM="$(grep -c 'u001e' "$RECORD" 2>/dev/null || echo 0)"
if [ "${Q14STRIP:-0}" -ge 1 ] && [ "${Q14TERM:-0}" -ge 1 ]; then
    ok "#1224 the comment read strips BOTH frame delimiters and terminates records (0x1e/0x1f) — the same frame the gate builds, so a comment body cannot forge a record"
else
    bad "#1224 the producer's comment read does not strip/terminate the frame (strip=$Q14STRIP term=$Q14TERM) — an unattested commenter could forge an admitted record and suppress the evidence post (finding 1b)"
fi
unset Q14STRIP Q14TERM
# A FAILED LIST READ IS NOT "NO COMMENTS": posting on it would duplicate the
# evidence on every transient API error, so the post must be skipped instead.
Q1224E="$T/p1224-comment-3.json"; : > "$Q1224E"
STUB_COMMENTS_FAIL=1 STUB_COMMENT_CAPTURE="$Q1224E" run_record "daniel-ospina/agent-infra" 424246
if [ -s "$Q1224E" ]; then
    bad "#1224 an unreadable comment list was treated as 'no comment' and the evidence was re-posted — a transient 5xx duplicates evidence"
else
    ok "#1224 an unreadable comment list SKIPS the post (skipped, never duplicated)"
fi
# ── THE BODY-READ-FAILURE ARM: exit 0 ONLY when the comment VERIFIABLY posted ──
# (prior review finding 3: reverting this whole arm — or making the comment post
# return 0 unconditionally — left the suite 970/0 GREEN, so the exit-0/exit-5
# contract had no coverage at all and the false-delivery claim was invisible.)
# ONE VECTOR PER OUTCOME, so each half of the contract is separately load-bearing:
#   (a) body read fails, comment posts        ⇒ rc 0 (CI CAN see the marker)
#   (b) body read fails, comment CANNOT post   ⇒ rc 5 (`body-marker-unposted`)
Q1224H="$T/p1224-comment-6.json"; : > "$Q1224H"
STUB_BODY_FAIL=1 STUB_COMMENT_CAPTURE="$Q1224H" run_record_rc "daniel-ospina/agent-infra" 424248 "$SHA"
if [ "$RECORD_RC" = "0" ] && [ -s "$Q1224H" ]; then
    ok "#1224 a body-read failure still exits 0 WHEN the evidence comment posted — the marker is visible to the required check, so the run is a success, not a false green"
else
    bad "#1224 a body-read failure did not use the comment channel (rc=$RECORD_RC, comment_posted=$([ -s "$Q1224H" ] && echo yes || echo no)) — either a review that IS evidenced reports failure, or it reports success with nothing delivered"
fi
Q1224I="$T/p1224-comment-7.json"; : > "$Q1224I"
STUB_BODY_FAIL=1 STUB_COMMENTS_FAIL=1 STUB_COMMENT_CAPTURE="$Q1224I" run_record_rc "daniel-ospina/agent-infra" 424249 "$SHA"
Q1224I_PENDING="$F_HOME/.pi/agent/reviews/pending/daniel-ospina__agent-infra-424249.marker"
if [ "$RECORD_RC" = "5" ] && [ ! -s "$Q1224I" ] && [ -f "$Q1224I_PENDING" ]; then
    ok "#1224 with NEITHER channel available the run exits 5 (body-marker-unposted) and KEEPS the pending marker — a failed delivery is a named state, never a warning on a zero exit"
else
    bad "#1224 a double delivery failure was not reported as the named exit-5 state (rc=$RECORD_RC, posted=$([ -s "$Q1224I" ] && echo yes || echo no), pending=$([ -f "$Q1224I_PENDING" ] && echo yes || echo no)) — the record would be invisible to CI while the run looks successful"
fi
unset Q1224H Q1224I Q1224I_PENDING
unset Q1224C Q1224C_BODY Q1224D Q1224E Q1224F Q1224G Q1224J Q6V Q6H Q6_RE Q6_RE_SIG

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

# ── 11.13k #3315 — THE CALLER-SUPPLIED RECORD PAIR (--recorded-diff/-head) ──
# WHY THIS EXISTS. check-pipeline-compliance.sh's check (c) is a REQUIRED status
# check and it runs on a CI runner, which has no $HOME/.pi/agent/reviews — it can
# only see the PR BODY's marker. So two gates read one record and disagreed: the
# producer said "the reviewed DIFF is UNCHANGED — carry it, do NOT re-review" from
# the record FILE, while check (c) refused the SAME record because its marker
# named an earlier head, and the only way through was minting an UNATTESTED marker
# at the current head — the shape tortoise#7391 forbids ("naming the PR's current
# head is not evidence"). The gate now hands in the marker's own
# (head, diff_sha256) pair and this mode answers.
#
# ⛔ THE VECTORS THAT MATTER ARE THE NEGATIVE ONES. A supplied pair must go
# through the SAME arms a record file does — carry / fresh / unreadable — and must
# never be accepted where it could not be: a changed diff, an unreadable diff, a
# non-identity digest (the empty-body constant), or any verb other than
# --check-carry. If any of those passed, the gate would be able to carry a record
# the merge gate refuses, which is the same two-gate disagreement inverted.
run_check_carry_pair() { # <pr> <repo> <recorded-head> <recorded-diff> -> CC_OUT / CC_RC
    CC_RC=0
    CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        STUB_DIFF_FILE="${STUB_DIFF_FILE:-$CC_DIFF}" STUB_DIFF_FAIL="${STUB_DIFF_FAIL:-0}" \
        STUB_HEAD_SHA="${STUB_HEAD_SHA:-$CC_HEAD}" \
        bash "$RECORD" --check-carry "$1" "$2" --recorded-diff "$4" --recorded-head "$3" 2>"$T/cc-err")" || CC_RC=$?
}
CC_PRIOR="$(printf 'e%.0s' $(seq 1 40))"
# (k1) THE CARRY, WITH NO RECORD FILE AT ALL — the CI-runner shape, and the whole
# point of the flag: same digest, different head, content identical.
rm -f "$CC_RDIR/424930.json" "$CC_FILE-424930.json"
run_check_carry_pair 424930 "$CC_REPO" "$CC_PRIOR" "$CC_SHA"
assert_eq "$CC_RC" "0" "11.13k1 a SUPPLIED pair matching the live diff is a carry without any record file (exit 0)"
assert_eq "$CC_OUT" "carry${CC_TAB}${CC_SHA}${CC_TAB}${CC_SHA}" "11.13k1 …and prints both digests, so the claim is checkable"
assert_contains "$(cat "$T/cc-err")" "caller-supplied record pair" "11.13k1 …and says WHICH source decided (the marker, not this box's file)"
# (k2) …and the SAME supplied shape with a CHANGED diff is still `fresh`: the flag
# buys an answer, never a lenient one.
run_check_carry_pair 424930 "$CC_REPO" "$CC_PRIOR" "$CC_DIFF_B"
assert_eq "$CC_RC" "1" "11.13k2 a supplied pair that does NOT match the live diff is 'fresh' (exit 1)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "fresh" "11.13k2 …reports 'fresh'"
# (k3) AN UNREADABLE DIFF IS NEVER A CARRY, with or without a record file — the
# fail-open this whole mode forbids ("could not read" → "unchanged").
STUB_DIFF_FAIL=1 run_check_carry_pair 424930 "$CC_REPO" "$CC_PRIOR" "$CC_SHA"
assert_eq "$CC_RC" "3" "11.13k3 a supplied pair over an UNREADABLE diff is refused (exit 3)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "unreadable" "11.13k3 …reports 'unreadable', never a carry"
unset STUB_DIFF_FAIL
# (k4) THE IDENTITY RULE STILL APPLIES: the empty-body constant would make every
# record match every PR, so it is `nodigest`, not a carry — however it was supplied.
run_check_carry_pair 424930 "$CC_REPO" "$CC_PRIOR" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
assert_eq "$CC_RC" "5" "11.13k4 the EMPTY-BODY constant is refused even when a caller supplies it (exit 5)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "nodigest" "11.13k4 …reports 'nodigest', not a carry"
# (k5) THE SUPPLIED PAIR IS THE QUESTION, NOT A HINT — a record file on this box
# must not override it. This box's record carries the OLD digest while the marker's
# is the live one; the caller asked about the marker, so `carry` is the answer.
cc_rec 424931 "$CC_STALE" "$CC_DIFF_B"
run_check_carry_pair 424931 "$CC_REPO" "$CC_PRIOR" "$CC_SHA"
assert_eq "$CC_RC" "0" "11.13k5 the supplied pair is answered even when a DIFFERENT record file exists (exit 0)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "carry" "11.13k5 …so it short-circuits the file lookup instead of deferring to it"
rm -f "$CC_FILE-424931.json"
# (k6..k8) THE FLAG CANNOT BE SMUGGLED ONTO ANOTHER VERB, and a malformed value
# is a usage error — never a silent pass. Each is its own exit-2, because each
# would otherwise let a caller believe something was pinned/recorded that was not.
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" bash "$RECORD" --check-carry 424930 "$CC_REPO" --recorded-head "$CC_PRIOR" 2>/dev/null)" || CC_RC=$?
assert_eq "$CC_RC" "2" "11.13k6 --recorded-head without --recorded-diff is refused (exit 2)"
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" bash "$RECORD" 424932 "$CC_HEAD" clean "$CC_REPO" --recorded-diff "$CC_SHA" 2>/dev/null)" || CC_RC=$?
assert_eq "$CC_RC" "2" "11.13k7 --recorded-diff on a MINTING invocation is refused (exit 2)"
assert_eq "$(ls "$CC_RDIR"/*424932* 2>/dev/null | wc -l | tr -d ' ')" "0" "11.13k7 …and no record was written"
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" bash "$RECORD" --check-carry 424930 "$CC_REPO" --recorded-diff "deadbeef" 2>/dev/null)" || CC_RC=$?
assert_eq "$CC_RC" "2" "11.13k8 a malformed --recorded-diff (not 64-hex) is refused (exit 2)"
# (k9) THE MUTATION PIN FOR THE SHORT-CIRCUIT: with the supplied arm removed, k1
# must fall back to the record lookup and answer `norecord` — proving k1 tests the
# supplied arm rather than a path that happened to be taken anyway.
CC_MUT2="$T/record-review-cc-supplied-mutant.sh"
cp "$RECORD" "$CC_MUT2"
if grep -q 'if \[ -n "\$RECORDED_DIFF" \]; then' "$CC_MUT2"; then
    sed -i.bak 's/^  if \[ -n "\$RECORDED_DIFF" \]; then$/  if false; then/' "$CC_MUT2"
    rm -f "$CC_MUT2.bak"
    if cmp -s "$RECORD" "$CC_MUT2"; then
        bad "11.13k9 the mutant is byte-identical to the script — the sed did not apply (re-anchor it)"
    fi
    CC_RC=0
    # ⚠️ THE MUTANT'S ARGUMENT PARSER STILL ACCEPTS THE FLAGS (only the arm is
    # disabled), so the flags must not be rejected as unknown here.
    CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        STUB_DIFF_FILE="$CC_DIFF" STUB_HEAD_SHA="$CC_HEAD" \
        bash "$CC_MUT2" --check-carry 424930 "$CC_REPO" --recorded-diff "$CC_SHA" --recorded-head "$CC_PRIOR" 2>/dev/null)" || CC_RC=$?
    if [ "$CC_RC" = "4" ]; then
        ok "11.13k9 mutation CAUGHT: with the supplied arm disabled the SAME request answers 'norecord' — so the arm is load-bearing"
    else
        bad "11.13k9 mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — k1 does not test the supplied arm"
    fi
else
    bad "11.13k9 the mutation anchor 'if [ -n \"\\\$RECORDED_DIFF\" ]; then' is gone — re-anchor it rather than dropping the pin"
fi
# (k10) A DIGEST-ONLY SUPPLIED PAIR IS A SUPPORTED SHAPE (review of #3315, P2):
# a pre-#2982 marker carries no head, so the gate hands in --recorded-diff alone.
# The content-identity verdict must be the same; only the head-binding arm and the
# rebase arm are unavailable, and NOTHING may be invented from the absent head
# (no `head` verdict, no `carry-patch` guess). Both directions are pinned here
# because both are reachable from check (c).
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    STUB_DIFF_FILE="$CC_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$CC_HEAD" \
    bash "$RECORD" --check-carry 424930 "$CC_REPO" --recorded-diff "$CC_SHA" 2>"$T/cc-err")" || CC_RC=$?
assert_eq "$CC_RC" "0" "11.13k10 --recorded-diff WITHOUT --recorded-head still carries on content identity (exit 0)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "carry" "11.13k10 …reports 'carry' (the absent head invents nothing)"
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    STUB_DIFF_FILE="$CC_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$CC_HEAD" \
    bash "$RECORD" --check-carry 424930 "$CC_REPO" --recorded-diff "$CC_DIFF_B" 2>"$T/cc-err")" || CC_RC=$?
assert_eq "$CC_RC" "1" "11.13k10 …and a NON-matching digest without a head is 'fresh', never a carry"

# (n) #10177 / #10522 (defect B): a CARRY that records NO PROOF is not a record.
#     The measured shape is tortoise#10677's: `mint:"carried"` onto a head whose
#     tree differed by 4 files/+178, with no `carry_arm` and no `evidence` — a
#     verdict re-bound to code nobody reviewed, and nothing in the artifact a
#     reader could check. The answer must be `norecord` (what a reader can act
#     on), never `head`.
CC_REC_10177="$CC_FILE-424919.json"
CC_HEAD_SAVED="$CC_HEAD"
CC_HEAD="$CC_SHA"
# A LITERAL 64-hex identity, not $CC_DIFF: §11.13's earlier arms reassign that
# variable, and a fixture digest that is not a valid identity makes every arm
# below answer `nodigest` for a reason of the fixture's own making.
CC_D64="$(printf 'c%.0s' {1..64})"
printf '{"pr":424919,"head_sha":"%s","diff_sha256":"%s","mint":"carried","carried_from":"%s","verdict":"clean","repo":"%s","reviewed_at":"2026-11-03T01:05:33Z"}\n' \
    "$CC_SHA" "$CC_D64" "$CC_STALE" "$CC_REPO" > "$CC_REC_10177"
run_check_carry 424919 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13n an UNPROVEN carry is NOT a record (exit 4)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "norecord" "11.13n …it answers norecord, not head/carry"
assert_contains "$(cat "$T/cc-err")" "CARRY with NO recorded proof" "11.13n …and names the reason a reader can act on"
# (n2) the SAME record WITH its proof binds at the head — the rule discriminates
#      on provenance, not on the word "carried".
printf '{"pr":424919,"head_sha":"%s","diff_sha256":"%s","mint":"carried","carry_arm":"lane","reviewed_diff_sha256":"%s","evidence":"comment:1","verdict":"clean","repo":"%s","reviewed_at":"2026-11-03T01:05:33Z"}\n' \
    "$CC_SHA" "$CC_D64" "$CC_D64" "$CC_REPO" > "$CC_REC_10177"
run_check_carry 424919 "$CC_REPO"
if [ "${CC_OUT%%"$CC_TAB"*}" != "norecord" ] && [ "$CC_RC" != "4" ]; then
    ok "11.13n2 the same carry WITH its proof is NOT denied as unproven (out=${CC_OUT%%"$CC_TAB"*}, rc=$CC_RC)"
else
    bad "11.13n2 a PROVEN carry is still refused as unproven (rc=$CC_RC, out=$CC_OUT) — the rule keys on the word 'carried', not on provenance"
fi
# (n3) MUTATION PIN — the unproven-carry rule must be LOAD-BEARING: with the
#      provenance test removed, the unproven record reads as a healthy head
#      again. That is the false green defect B is about, so a pin that stays
#      green on the mutant proves nothing.
CC_MUT_K="$T/record-review-10177-mutant.sh"
cp "$RECORD" "$CC_MUT_K"
if grep -qF 'if [ -z "$CC_ARM_F" ] || [ -z "$CC_EV_F" ]; then' "$CC_MUT_K"; then
    sed -i.bak 's/^[[:space:]]*if \[ -z "\$CC_ARM_F" \] || \[ -z "\$CC_EV_F" \]; then$/    if false; then/' "$CC_MUT_K"
    rm -f "$CC_MUT_K.bak"
    if cmp -s "$RECORD" "$CC_MUT_K"; then
        bad "11.13n3 the mutant is byte-identical to the script — the sed did not apply (re-anchor it)"
    fi
    printf '{"pr":424919,"head_sha":"%s","diff_sha256":"%s","mint":"carried","carried_from":"%s","verdict":"clean","repo":"%s","reviewed_at":"2026-11-03T01:05:33Z"}\n' \
        "$CC_SHA" "$CC_D64" "$CC_STALE" "$CC_REPO" > "$CC_REC_10177"
    run_check_carry 424919 "$CC_REPO" "$CC_MUT_K"
    if [ "${CC_OUT%%"$CC_TAB"*}" != "norecord" ]; then
        ok "11.13n3 MUTATION CAUGHT: without the provenance test the UNPROVEN carry stops reading as 'norecord' (it answers ${CC_OUT%%"$CC_TAB"*}) — so 11.13n is load-bearing"
    else
        bad "11.13n3 mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — 11.13n cannot fail, so it proves nothing"
    fi
else
    bad "11.13n3 the mutation anchor 'if [ -z \"\\\$CC_ARM_F\" ] || [ -z \"\\\$CC_EV_F\" ]; then' is gone — re-anchor the pin rather than dropping it"
fi
# (n4) #10583 × #10177 — a `mint:"delta"` record IS a carry, so the same provenance rule
#      must reach it. A delta re-binds a verdict minted at ANOTHER head exactly as a
#      `carried` record does (the only difference is how the reviewed head was found), so
#      exempting it would make the delta verb the ONE carry path that can re-bind a `clean`
#      onto a tree with nothing in the record a reader could check — the tortoise#10677
#      shape. The record here carries a full `delta` object and still names NO arm and NO
#      evidence, so the refusal must come from the missing PROOF, not from the mint word:
#      a real delta record DOES write top-level `carry_arm` and `evidence`, so naming the mint
#      alone buys nothing. The write is the `CARRY_FIELDS="\"carry_arm\":\"$CARRY_ARM\","` line
#      (scripts/record-review.sh:6324 at this head — RE-DERIVE it, do not trust the number: a bare
#      line citation here has rotted before, and this comment is not what makes
#      the assertion true). One command answers it (origin/main bd1b205d is :6225):
#        grep -n 'CARRY_FIELDS=.*carry_arm' scripts/record-review.sh
printf '{"pr":424920,"head_sha":"%s","diff_sha256":"%s","mint":"delta","carried_from":"%s","delta":{"from":"%s","to":"%s","proved":"lane","arm":"lane"},"verdict":"clean","repo":"%s","reviewed_at":"2026-11-03T01:05:33Z"}\n' \
    "$CC_SHA" "$CC_D64" "$CC_STALE" "$CC_STALE" "$CC_SHA" "$CC_REPO" > "$CC_FILE-424920.json"
run_check_carry 424920 "$CC_REPO"
assert_eq "$CC_RC" "4" "11.13n4 an UNPROVEN delta is NOT a record either (exit 4)"
assert_eq "${CC_OUT%%"$CC_TAB"*}" "norecord" "11.13n4 …it answers norecord, not head — a delta cannot escape the provenance rule"
rm -f "$CC_FILE-424920.json"
rm -f "$CC_REC_10177"
CC_HEAD="$CC_HEAD_SAVED"

unset CC_OUT CC_RC CC_REPO CC_RDIR CC_HEAD CC_STALE CC_DIFF CC_DIFF_B CC_SHA CC_FILE CC_MUT CC_TAB CC_NONDIFF CC_CAP406 CC_PRIOR CC_MUT2


# ─────────────────────────────────────────────────────────────────────────
# 11.14 #2872 — `--recover-body`: rebuild a MISSING record from the PR body's
#       SIGNED marker.
# ─────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS. The record file is PER BOX; the signed marker in the PR body was
# the only copy of the verdict that TRAVELLED until #1224 added the comment copy. Measured 2026-10-26:
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
# status CHECKED, then exported. This site is the class the scanner's rule CANNOT see (a declaration
# builtin whose value spans lines is not "a substitution on the same line"), and it is still the shape:
# a marker that failed to BUILD leaves the prose prefix non-empty, so the arm goes red for the wrong
# reason instead of refusing to judge. The marker is therefore built and checked BEFORE it is embedded.
RB_M_A="$(rb_marker 424911 "review recorded: reviews/424911.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — the 11.14a arm would otherwise fail on a MISSING marker"
STUB_BODY="Some PR description.

$RB_M_A"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$RB_TEXT_B sig=$(printf '0%.0s' $(seq 1 64))" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424915 "review recorded: reviews/424915.json verdict=clean @ $RB_HEAD diff=$RB_DIFF (daniel-ospina/tortoise)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424918 "review recorded: reviews/424918.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
run_recover 424918 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14h an existing record is not replaced (exit 5)"
assert_eq "$(cat "$RB_EXIST")" "$RB_BEFORE" "11.14h …byte-identical afterwards"

# (i) AN HONEST reviewed_at IS NOT NEGOTIABLE. If the head commit's date cannot
#     be read, refuse — stamping `now` as a mint time is the tortoise#7391 defect.
rb_clear
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424919 "review recorded: reviews/424919.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
    # status CHECKED, then exported: `export X="$(…)"` discards the substitution's
    # status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
    # below refuse for the WRONG reason and still pass.
    STUB_BODY="$RB_TEXT_M sig=$(printf '0%.0s' $(seq 1 64))" \
      || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
    export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424922 "review recorded: reviews/424922.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424923 "review recorded: reviews/424923.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424924 "review recorded: reviews/424924.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
run_recover 424924 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14n a legacy record naming THIS repo is not replaced (exit 5)"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424924.json" ]; then bad "11.14n a qualified record was minted beside an existing legacy one"; else ok "11.14n …and no qualified record is minted beside it"; fi
rb_clear
printf '%s\n' '{"pr":424925,"head_sha":"ffffffffffffffffffffffffffffffffffffffff","verdict":"clean","mint":"fresh","repo":"daniel-ospina/tortoise","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_RDIR/424925.json"
RB_FOREIGN_BEFORE="$(cat "$RB_RDIR/424925.json")"
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424925 "review recorded: reviews/424925.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED PER MARKER, then exported. ⛔ A single trailing guard on a TWO-substitution value
# checks only the LAST one (`X="…$(a)…$(b)"` returns b's status), so a failing FIRST marker would still
# be discarded — and the arm asserts the LAST marker wins by name, so it would stay green while proving
# nothing about supersession. Each marker is built and checked on its own, so either failure is loud.
RB_M_FIRST="$(rb_marker 424926 "review recorded: reviews/424926.json verdict=clean @ $RB_OLD_HEAD diff=$RB_OLD_DIFF ($RB_REPO)")" \
  || bad "fixture: the SUPERSEDED marker could not be BUILT — 11.14o would otherwise prove nothing about supersession"
RB_M_LAST="$(rb_marker 424926 "review recorded: reviews/424926.json verdict=clean-micro @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: the LAST marker could not be BUILT — an empty last marker would make recovery refuse for the WRONG reason"
STUB_BODY="$RB_M_FIRST
$RB_M_LAST"
export STUB_BODY
run_recover 424926 "$RB_REPO"
assert_eq "$RB_RC" "0" "11.14o two markers for one PR: recovery succeeds (exit 0)"
assert_contains "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424926.json" 2>/dev/null)" "\"head_sha\":\"$RB_HEAD\"" "11.14o …restoring the LAST marker's head, not the first"
assert_contains "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424926.json" 2>/dev/null)" '"verdict":"clean-micro"' "11.14o …and its verdict, not the superseded one"

# (p) THE LEGACY DIFF-LESS MARKER: a marker minted before #2982 has no `diff=`.
#     The recovered record then carries NO digest — honestly, rather than a guess —
#     and `--check-carry` answers `nodigest` (5), not `fresh` (1): "no digest to
#     compare" and "the diff changed" are different facts with different remedies.
rb_clear
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424927 "review recorded: reviews/424927.json verdict=clean @ $RB_HEAD ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424928 "review recorded: reviews/424928.json verdict=clean-low @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
run_recover 424928 "$RB_REPO"
assert_eq "$RB_RC" "3" "11.14q a clean-low marker is refused (exit 3)"
assert_contains "$(cat "$T/rb-err")" "FRESH mint (not a carry" "11.14q …and names the remedy that IS available, correctly labelled (a fresh mint, not a carry)"
assert_contains "$(cat "$T/rb-err")" "record-review.sh 424928" "11.14q …with the exact command to run"
if [ -f "$RB_RDIR/daniel-ospina-agent-infra-424928.json" ]; then bad "11.14q a clean-low record was minted without merge_base_sha"; else ok "11.14q …and nothing is written"; fi

# (r) ONE VERB PER INVOCATION. `--recover-body --check-carry` would print a
#     read-only answer and exit 0 having written NOTHING — a successful-looking
#     recovery that did not happen.
rb_clear
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424929 "review recorded: reviews/424929.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424930 "review recorded: reviews/424930.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424931 "review recorded: reviews/424931.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
    # status CHECKED, then exported: `export X="$(…)"` discards the substitution's
    # status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
    # below refuse for the WRONG reason and still pass.
    STUB_BODY="$(rb_marker 424932 "review recorded: reviews/424932.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
      || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
    export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424933 "review recorded: reviews/424933.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
export STUB_RACE_PATH="$RB_RDIR/daniel-ospina-agent-infra-424933.json" STUB_RACE_RECORD="$RB_FOREIGN_JSON"
run_recover 424933 "$RB_REPO"
unset STUB_RACE_PATH STUB_RACE_RECORD
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424933 "review recorded: reviews/424933.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
assert_eq "$RB_RC" "5" "11.14v a FOREIGN record appearing mid-recovery is not destroyed (exit 5)"
assert_eq "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424933.json" 2>/dev/null)" "$RB_FOREIGN_JSON" "11.14v …the other repo's verdict survives byte-identical"

# (w) A CORRUPT RECORD IS NOT "NOTHING TO REPAIR". A truncated file parses to no
#     `repo`, which the ownership test reads as unowned — so the plain refusal
#     would assert there is nothing to fix about a file the GATE calls corrupt.
rb_clear
printf '%s' '{"pr":424934,"head_sha":"abc' > "$RB_RDIR/daniel-ospina-agent-infra-424934.json"
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424934 "review recorded: reviews/424934.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
run_recover 424934 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14w a corrupt record is refused (exit 5)"
assert_contains "$(cat "$T/rb-err")" "NOT a usable record" "11.14w …and it is named as unusable, not as 'nothing to repair'"
assert_contains "$(cat "$T/rb-err")" "move it aside" "11.14w …with a way out"

# (x) NO SILENT POSITIONAL DROP. `--recover-body 42 o/r clean-low <sha>` used to
#     take $2 as the repo and DISCARD the verdict and head, minting the marker's
#     verdict with exit 0 while the caller believed it had chosen one.
rb_clear
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424935 "review recorded: reviews/424935.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424936 "review recorded: reviews/424936.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
run_recover 424936 "$RB_REPO"
assert_eq "$RB_RC" "5" "11.14y a pretty-printed (jq round-trip) record counts as existing (exit 5)"
assert_contains "$(cat "$T/rb-err")" "already exists" "11.14y …and is NOT called unusable, because the gate reads it fine"

# (y2) PRESENT BUT UNTYPED IS NOT A RECORD. The gate requires STRINGS, so
#      `"head_sha": null` is ABSENT to it. Treating that as an existing record
#      here would answer "nothing to repair" for a file the rail says NO-RECORD
#      about — the round-2 loop, narrowed to a present-but-untyped key.
rb_clear
printf '%s\n' '{"pr":424938,"head_sha":null,"verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-02-02T00:00:00Z"}' > "$RB_RDIR/daniel-ospina-agent-infra-424938.json"
# status CHECKED, then exported: `export X="$(…)"` discards the substitution's
# status, so a fixture that failed to BUILD (empty STUB_BODY) would make the arm
# below refuse for the WRONG reason and still pass.
STUB_BODY="$(rb_marker 424938 "review recorded: reviews/424938.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — this arm would otherwise pass on an EMPTY body"
export STUB_BODY
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
sed 's#^  clean|clean-micro|clean-low|not-clean) ;;#  clean|clean-micro) ;;#' "$RECORD" > "$MUTANT_PRE"
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
# ── #10177 / #10522 (defect B): a carry must SAY WHAT IT CARRIED ─────────
# Before this, a carried record was indistinguishable from a stale re-record: no
# arm, no reviewed digest, and no evidence (the measured tortoise#10677 record
# carried `clean` across 4 files/+178 with `evidence:null`). The evidence field
# is now ALWAYS populated, and never with the caller's unverified --evidence.
assert_contains "$R13H" '"evidence":"comment:' "13h the carry INHERITS the predecessor's evidence ref (a carry re-binds a verdict, it does not mint one)"
assert_not_contains "$R13H" '"evidence":""' "13h a carried record NEVER mints an empty evidence field (\"no verdict\", not \"trust me\")"
assert_contains "$R13H" '"carry_arm":"diff"' "13h the record names the ARM that proved the artifact unchanged"
assert_contains "$R13H" '"reviewed_diff_sha256":' "13h the record keeps the digest the REVIEWED head carried"
assert_contains "$R13H" '"reviewed_diff_source":"marker"' "13h …and says where that digest came from"
# `carried_delta_sha256` is written only when BOTH commits are local, and this
# fixture's heads are synthetic (`aaaa…`/`bbbb…`), so here the field is legitimately
# absent. ⛔ ITS WRITER IS THEREFORE **NOT PINNED BY THIS SECTION** — fresh-review
# cycle 3 measured that deleting the write leaves every assertion above green, and an
# "absent ⇒ ok" arm is not a test (cycle 2's version claimed a premise no world could
# falsify). The honest pin needs a LANE-arm fixture with real commits; it is filed as
# a follow-up rather than faked here. What is asserted instead is the SHAPE of the
# field whenever it IS present, so a malformed digest still reddens.
if grep -q '"carried_delta_sha256":"' <<<"$R13H"; then
    R13H_DELTA="$(sed -n 's/.*"carried_delta_sha256":"\([^"]*\)".*/\1/p' <<<"$R13H")"
    if [[ "$R13H_DELTA" =~ ^[0-9a-f]{64}$ ]]; then ok "13h carried_delta_sha256 is a 64-hex digest when written"; else bad "13h carried_delta_sha256 is not a 64-hex digest ($R13H_DELTA)"; fi
fi

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

# ── agent-infra#3442 — THE MUTATION-ATTRIBUTION FIXTURE ─────────────────────────────────────────
# The contract changed: a FRESH `clean` record now requires its artifact to carry the
# `## MUTATION ATTRIBUTION` block (`verify_review_evidence`'s last arm), because five PRs in one night
# were reviewed clean over assertions that stay GREEN with the bug restored. Every arm below whose
# SUBJECT is something else (the state arm, the Outcome: precision arm, the over-block guards) must
# therefore carry the block, or it would be refused by the non-vacuity arm and would report a green
# for a reason unrelated to what it pins — the unrelated-row trap #3442 rule 2 names. This is the
# SHAPE only; the parser is `brief-gate.sh --mutation-missing` and the arms that pin the shape itself
# live in the "#3442" block at the end of this section.
VACUITY_BLOCK='## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| test.sh:12 the gate refuses an empty brief | sed s/rc=80/rc=0/ x.sh | section A (i) | rc=0, wanted 80 |'

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
# ⛔ #3442 NARROWS THE RESIDUAL WITHOUT CLOSING IT, AND SAYS WHICH: the artifact must now carry an
# attribution block, so a bare bot comment is no longer clean evidence — but a bot comment that
# CARRIES one still is, and that is the arm below. The declared limit is unchanged (the gate still
# does not judge whether the artifact is a review); what changed is that the artifact must say
# something only a review could say.
rm -f "$(Q2 424744)"
EV_REF="comment:42474401" run_record_ev 424744 STUB_EVIDENCE_BODY="🤖 Mergify: your pull request has been merged automatically.

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13l (DECLARED OUT OF SCOPE, NARROWED by #3442) a non-review artifact CARRYING the block is still ACCEPTED — the gate checks artifact, not review"
R13L="$(cat "$(Q2 424744)" 2>/dev/null || true)"
assert_contains "$R13L" '"evidence":"comment:42474401"' "13l the record names the non-review artifact it accepted"
assert_contains "$R13L" '"mint":"fresh"' "13l the looser path is still a fresh mint (provenance unaffected)"
# ⛔ …and the SAME bot comment WITHOUT the block is now refused, which is the half #3442 adds. Asserted
# in the same vector so a later edit to the arm above cannot re-open the bare-bot-comment route.
rm -f "$(Q2 424794)"
EV_REF="comment:42479401" run_record_ev 424794 STUB_EVIDENCE_BODY="🤖 Mergify: your pull request has been merged automatically."
assert_eq "$RECORD_RC" "3" "13l a bare bot comment (no attribution block) is REFUSED as clean evidence (#3442)"
[ ! -f "$(Q2 424794)" ] && ok "13l no record minted from a bare bot comment" || bad "13l minted a record from a bare bot comment"


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

All three fixed in 9f1a2b3.

$VACUITY_BLOCK"
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

One test failed on origin/main and passes here.

$VACUITY_BLOCK"
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

No issues remain after the fixes in 9f1a2b3.

$VACUITY_BLOCK"
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

# ── agent-infra#1889 — THE CLEAN [ADVERSARIAL-BOUND] FORM ───────────────────────────────
# The token is emitted for TWO different exits: `fixer-loop.md` §"PR comment prefix" uses it for
# `EXIT_REASON == "adversarial-capped"`, and `AGENTS.md` §Hard Cap REQUIRES it as the disclosure of a
# CLEAN threat-coverage exit (`residuals=none`). Matching the bare token refused the honest case —
# the lane whose verifier returned `THREAT SURFACE COVERED` with 0 issues and nothing filed — and the
# cheapest way to pass became DROPPING the mandated disclosure. The arm now reads the token's own
# `residuals=` field. Both directions are pinned: the acceptance alone would let a fail-open land
# ("any [ADVERSARIAL-BOUND] is clean"), the refusals alone would let the false refusal return.
rm -f "$(Q2 424860)"
EV_REF="comment:42486001" run_record_ev 424860 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

Every declared threat class is covered by a test. No in-scope bypass reproduced; nothing filed.

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals=none — bounded by the declared threat surface (agent-infra#838)

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6b the CLEAN [ADVERSARIAL-BOUND] form (residuals=none) is ACCEPTED (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
R13M6B="$(cat "$(Q2 424860)" 2>/dev/null || true)"
assert_contains "$R13M6B" '"evidence":"comment:42486001"' "13m6b the accepted artifact is the one the record names"
assert_contains "$R13M6B" '"mint":"fresh"' "13m6b the clean form mints a FRESH record, not a carry"

# 13m6c — an UNPARSEABLE disclosure is a cannot-verify, never a pass: a marker with no `residuals=`
# field at all must refuse. (Fail-closed on the axis the acceptance above would otherwise widen.)
rm -f "$(Q2 424861)"
EV_REF="comment:42486101" run_record_ev 424861 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6c an [ADVERSARIAL-BOUND] with no residuals= field is refused (rc 3)"
[ ! -f "$(Q2 424861)" ] && ok "13m6c no record minted from an unparseable disclosure" || bad "13m6c minted from an unparseable disclosure"

# 13m6d — near-miss VALUES must refuse, or the field is a rubber stamp: a residuals list appended to
# the clean word, a suffix on it, and the UNSUBSTITUTED template a lane copies without filling in.
# ⛔ THE COUNTS ARE EQUAL ON PURPOSE (#3829 F1). These bodies used to carry `covered=15 threats=17`,
# which is ALSO the shape arm (iv) refuses as a contradiction — so the refusal was over-determined and
# relaxing only the exact-value predicate left all four rows GREEN: the row could not tell "the value
# check works" from "the counts disagree" (agent-infra#3442 rule 2, attributable catch). With
# `threats=17 covered=17` no contradiction exists, so axis (ii) is the ONLY reason to refuse — and
# 13m6j pins that attribution by relaxing axis (ii) alone.
_m6d=0
for _m6d_val in 'none,#12' 'none-filed' 'none#12' '<#N,…|none>'; do
    _m6d=$((_m6d + 1)); _m6d_pr=$((424861 + _m6d))
    rm -f "$(Q2 $_m6d_pr)"
    EV_REF="comment:${_m6d_pr}01" run_record_ev "$_m6d_pr" \
        STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals=${_m6d_val}

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6d residuals='${_m6d_val}' is not the clean value — refused (rc 3)"
done

# 13m6e — THE LAUNDERING GUARD. One capped marker refuses the artifact however many clean ones sit
# beside it, in either order: "the disclosure mentions residuals=none" must never rescue an artifact
# whose own exit was capped (a comment may carry several markers when a lane pastes its cycle log).
rm -f "$(Q2 424870)"
EV_REF="comment:42487001" run_record_ev 424870 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals=none — cycle 1, nothing filed

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#12,#14 — cycle 2, residuals filed

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6e a clean marker beside a CAPPED one still refuses (rc 3)"
rm -f "$(Q2 424871)"
EV_REF="comment:42487101" run_record_ev 424871 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#12 — if residuals=none it would be clean

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6e prose mentioning residuals=none cannot launder a capped marker (rc 3)"

# 13m6h — THE CASE-INSENSITIVE TRIGGER MUST NOT MEET A CASE-SENSITIVE DETECTOR (found in review of
# this change, and it was a REAL fail-open). The outer trigger is `grep -qiE`, so a body spelling the
# marker `[adversarial-bound]` entered the arm; the first cut's per-line `case *'[ADVERSARIAL-BOUND]'*`
# is case-SENSITIVE, matched nothing, and the whole arm was skipped — a CAPPED marker in lower case
# minted `clean`. Both directions are pinned: the lower-case CAPPED form refuses, and the lower-case
# CLEAN form is still accepted (so the repair cannot be "veto anything lower case" either).
rm -f "$(Q2 424890)"
EV_REF="comment:42489001" run_record_ev 424890 STUB_EVIDENCE_BODY="## Review

[adversarial-bound] cycles=2 threats=17 covered=15 residuals=#12,#14 — residuals filed, not chased

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6h a LOWER-CASE [adversarial-bound] with residuals filed is refused (rc 3)"
[ ! -f "$(Q2 424890)" ] && ok "13m6h no record minted from a lower-case capped marker" || bad "13m6h minted from a lower-case capped marker"
rm -f "$(Q2 424891)"
EV_REF="comment:42489101" run_record_ev 424891 STUB_EVIDENCE_BODY="## Review

[adversarial-bound] cycles=2 threats=17 covered=17 residuals=none — bounded by the declared threat surface

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6h the LOWER-CASE clean form is still ACCEPTED (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tail -1)]"

# 13m6i — A CONTRADICTORY DISCLOSURE IS NOT A CLEAN ONE. `covered` below `threats` is the artifact's
# own admission that a declared class went uncovered, so `residuals=none` beside it cannot be true —
# and pre-#1889 the bare token refused it, so accepting it would be a NEW fail-open introduced by this
# change (raised as a measured, out-of-surface gap in the fresh review at `9ecc4679f`; closed here
# because this lane was re-pushing anyway). The other half is a guard against over-correction: a TERSE
# marker that carries no counts still passes, because demanding them would re-create the friction
# #1889 exists to remove.
rm -f "$(Q2 424892)"
EV_REF="comment:42489201" run_record_ev 424892 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=none — two declared classes uncovered

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6i covered < threats with residuals=none is a contradiction — refused (rc 3)"
[ ! -f "$(Q2 424892)" ] && ok "13m6i no record minted from a self-contradictory clean disclosure" || bad "13m6i minted from a contradictory disclosure"
rm -f "$(Q2 424893)"
EV_REF="comment:42489301" run_record_ev 424893 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] residuals=none

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6i the TERSE clean form (no counts) is still ACCEPTED — the arm checks contradiction, not completeness (rc 0)"

# 13m6f — MUTATION PIN (the CAPPED direction). With the whole residuals= arm DISABLED, 13m6's capped
# marker must be ACCEPTED — if it still refuses, 13m6 is passing on some other arm and this fix's
# discrimination is untested. Built from THIS script into $T, never edited in place.
_m6f_mut="$T/record-review.mut1889-noarm.sh"
command sed 's#^  if grep -qiE .*ADVERSARIAL-BOUND.*$#  if false; then#' "$RECORD" > "$_m6f_mut"
if command grep -q 'if false; then' "$_m6f_mut" && ! cmp -s "$_m6f_mut" "$RECORD"; then
    _m6f_pr=424880
    rm -f "$(Q2 $_m6f_pr)"
    EV_REF="comment:${_m6f_pr}01" run_record_ev "$_m6f_pr" RECORD="$_m6f_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#12,#14 — residuals filed, not chased

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6f MUTATION: with the residuals= arm disabled a CAPPED marker is ACCEPTED (rc 0) — 13m6 is load-bearing"
else
    bad "13m6f could not build the mutant copy — the pin did not run"
fi

# 13m6g — MUTATION PIN, the other direction: with the CLEAN-form acceptance removed (every marker
# vetoed unconditionally, the pre-#1889 behaviour) 13m6b must be REFUSED.
_m6g_mut="$T/record-review.mut1889b.sh"
command sed 's#^[[:space:]]*grep -qiE .\^residuals=.*$#            false || _ab_ok=0#' "$RECORD" > "$_m6g_mut"
if command grep -q 'false || _ab_ok=0' "$_m6g_mut" && ! cmp -s "$_m6g_mut" "$RECORD"; then
    _m6g_pr=424881
    rm -f "$(Q2 $_m6g_pr)"
    EV_REF="comment:${_m6g_pr}01" run_record_ev "$_m6g_pr" RECORD="$_m6g_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals=none — bounded by the declared threat surface

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6g MUTATION: without the clean-form branch a residuals=none marker is REFUSED (rc 3) — 13m6b is load-bearing"
else
    bad "13m6g could not build the mutant copy — the pin did not run"
fi

# 13m6j — MUTATION PIN (attribution for axis (ii), #3829 F1). 13m6d asserts that a near-miss
# `residuals=` value refuses; this pin proves the VALUE predicate at `record-review.sh` is what refuses
# it. With that one predicate replaced by an unconditional accept (`_ab_ok=1`) — everything else
# untouched — the same 13m6d-shaped body must be ACCEPTED (vector A). Before 13m6d's bodies dropped the
# `covered=15 threats=17` counts this vector would have been REFUSED, because arm (iv) refuses that
# shape on its own and the row passed for the wrong reason — so vector B pins the over-determination
# itself: on the SAME mutant, the pre-fix counts refuse while the equal counts accept. Re-adding the
# counts to 13m6d would therefore redden this pin, not silently re-shadow the four rows. (The mutant's
# replacement text is `_ab_ok=1`, not `true`: after #3829 F1 the value is judged POSITIVELY, so a bare
# `true` would leave the value UNJUDGED and the near-misses would still refuse via the filed-list
# grammar — the pin would then be measuring the wrong line.)
# Built from THIS script into $T, never edited in place.
_m6j_mut="$T/record-review.mut1889c.sh"
command sed 's#^[[:space:]]*grep -qiE .\^residuals=.*$#            _ab_ok=1#' "$RECORD" > "$_m6j_mut"
if ! command grep -qF "grep -qiE '^residuals=" "$_m6j_mut" && ! cmp -s "$_m6j_mut" "$RECORD"; then
    _m6j_pr=424882
    rm -f "$(Q2 $_m6j_pr)"
    EV_REF="comment:${_m6j_pr}01" run_record_ev "$_m6j_pr" RECORD="$_m6j_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals=none,#12 — residuals filed

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6j MUTATION A: with the exact-value predicate relaxed a near-miss residuals= value is ACCEPTED (rc 0) — 13m6d is load-bearing"
    # Vector B — the SAME mutant, only the counts differ, and the verdict flips. That IS the
    # over-determination: with unequal counts the row would have been green while axis (ii) was dead,
    # which is exactly what #3829 F1 measured.
    _m6j_pr=424883
    rm -f "$(Q2 $_m6j_pr)"
    EV_REF="comment:${_m6j_pr}01" run_record_ev "$_m6j_pr" RECORD="$_m6j_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=none,#12 — residuals filed

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6j MUTATION B: with UNEQUAL counts the same near-miss value still refuses on the same mutant — the pre-fix shadowing, which is why 13m6d carries threats=covered"
    # Vector C — and the trap is not merely described: the §13m6d loop body must NOT reintroduce
    # UNEQUAL counts, because that is the root F1 names. Reads THIS file at run time and compares the two
    # numbers it finds, so a future edit that "restores" ANY unequal pair (not just the one number an
    # earlier draft hard-coded as `covered=1[5]`) reddens HERE instead of silently re-shadowing the four
    # rows (agent-infra#3442 rule 2: the catch must be attributable). A body with NO counts is accepted by
    # this guard on purpose — arm (iv) cannot fire without both fields, so axis (ii) is then the only
    # reason those four rows can refuse, which is exactly what 13m6d needs.
    _m6j_loopline="$(command grep -E 'residuals=\$\{_m6d_val\}' "${BASH_SOURCE[0]}" | command head -n 1)"
    _m6j_lt="$(printf '%s' "$_m6j_loopline" | command grep -oE 'threats=[0-9]+' | command grep -oE '[0-9]+' | command head -n 1)"
    _m6j_lc="$(printf '%s' "$_m6j_loopline" | command grep -oE 'covered=[0-9]+' | command grep -oE '[0-9]+' | command head -n 1)"
    if [ -n "$_m6j_lt" ] && [ -n "$_m6j_lc" ] && [ "$_m6j_lt" != "$_m6j_lc" ]; then
        bad "13m6j the §13m6d loop body carries UNEQUAL counts (threats=${_m6j_lt} vs covered=${_m6j_lc}) — it is over-determined by arm (iv) again, so its four rows cannot tell axis (ii) from a contradiction (#3829 F1)"
    else
        ok "13m6j the §13m6d loop body carries no contradiction (threats='${_m6j_lt:-none}' covered='${_m6j_lc:-none}'), so axis (ii) is the only reason those four rows refuse"
    fi
else
    bad "13m6j could not build the axis-(ii) mutant copy — the pin did not run"
fi

# 13m6k — THE FINDING'S OWN ROW (agent-infra#3829 F1). A CLEAN bounded exit that FILED residual
# follow-ups. The recorded decision (`AGENTS.md` §Hard Cap) makes the acceptance criterion COVERAGE —
# "every declared threat class covered by a test + green CI" — makes residuals "filed from cycle 1, not
# chased", and renders the field `<#N,…|none>`, so a filed list IS a legal clean value. Two merged plans
# record exactly this shape as a clean exit (`docs/plans/2026-09-15-issue-1051-bounded-scan-root.md` →
# `threats=11 covered=11 residuals=#1083,#1084,#1096`; `docs/plans/2026-09-28-issue-1505-…` →
# `covered=5 residuals=R-B1..R-B6 + C6`). Nothing in the suite could tell the shipped `residuals=none`
# predicate from the correct count-based one — every other row is refused by the unequal counts or by a
# value that MENTIONS `none` — which is why the wrong discriminator survived five review rounds.
rm -f "$(Q2 424894)"
EV_REF="comment:42489401" run_record_ev 424894 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

Every declared threat class C1–C11 is covered by a test. Three findings outside the declared surface
are filed as follow-ups and deliberately not chased.

[ADVERSARIAL-BOUND] cycles=2 threats=11 covered=11 residuals=#1083,#1084,#1096 — acceptance is declared-threat-surface coverage, not a literal NO ISSUES FOUND

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6k the CLEAN bounded exit WITH FILED residuals (equal counts) is ACCEPTED (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
# Vector B — the FAIL-CLOSED boundary of that acceptance: the filed form's legality rests on the
# coverage comparison, so with NO counts it is a cannot-verify and must refuse — the same posture as a
# marker with no `residuals=` field (13m6c). Without this vector "any non-template value is clean"
# would pass silently.
rm -f "$(Q2 424895)"
EV_REF="comment:42489501" run_record_ev 424895 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] residuals=#1083,#1084 — residuals filed, not chased

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6k a FILED residual list with NO counts is a cannot-verify — refused (rc 3)"
[ ! -f "$(Q2 424895)" ] && ok "13m6k no record minted from an unverifiable filed list" || bad "13m6k minted from a filed list whose coverage cannot be checked"
# Vector C — the filed form cannot LAUNDER an uncovered surface: `covered` below `threats` refuses
# before the value is even judged, which is what keeps the count-based acceptance from becoming a
# fail-open (the one way "filed residuals are legal" could be abused).
rm -f "$(Q2 424896)"
EV_REF="comment:42489601" run_record_ev 424896 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#1083,#1084 — residuals filed, not chased

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6k filed residuals with covered < threats is a contradiction — refused (rc 3)"
[ ! -f "$(Q2 424896)" ] && ok "13m6k no record minted from a filed list that admits an uncovered class" || bad "13m6k minted from a filed list beside an uncovered class"

# 13m6l — MUTATION PIN (attribution for the FILED-value branch itself). 13m6k asserts that a filed
# list with equal counts is ACCEPTED; this pin proves THAT branch is what accepts it. With the branch
# disabled (`:` in place of the condition) the identical body must REFUSE, and — the control, so the
# pin cannot pass by having killed the whole arm — a `residuals=none` body with the same counts must
# still ACCEPT on the same mutant.
_m6l_mut="$T/record-review.mut1889d.sh"
command sed 's#^[[:space:]]*if \[ "\$_ab_ok" -ne 1 \] &&.*$#            :#' "$RECORD" > "$_m6l_mut"
# The `&&` above is load-bearing: without it the pattern also matches the POST-LOOP check
# (`if [ "$_ab_ok" -ne 1 ] || [ "$_ab_n" -eq 0 ]`), leaving the mutant unparseable — measured, rc 2.
# ⛔ IT NOW MATCHES ONE LINE PER FILED SPELLING (#3829 review): the branch is deliberately TWO
# self-contained one-liners, a numeric list and the bare word `filed`, so this pin disables BOTH and the
# control below still proves the ARM survived. That is why each spelling must stay a single line — a
# multi-line `if …; then / … / fi` would leave this pattern matching only the header and the mutant
# would not parse (measured: the pin reported "could not build the filed-value mutant copy").
# So the pin self-checks BOTH that the branch went and that the mutant still parses.
if ! command grep -qF 'none|<|>|…' "$_m6l_mut" && command grep -qF '[ "$_ab_ok" -ne 1 ] ||' "$_m6l_mut" \
   && bash -n "$_m6l_mut" 2>/dev/null && ! cmp -s "$_m6l_mut" "$RECORD"; then
    _m6l_pr=424897
    rm -f "$(Q2 $_m6l_pr)"
    EV_REF="comment:${_m6l_pr}01" run_record_ev "$_m6l_pr" RECORD="$_m6l_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=11 covered=11 residuals=#1083,#1084,#1096 — residuals filed, not chased

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6l MUTATION: with the filed-value branch disabled a filed list (equal counts) is REFUSED (rc 3) — 13m6k is load-bearing"
    _m6l_pr=424898
    rm -f "$(Q2 $_m6l_pr)"
    EV_REF="comment:${_m6l_pr}01" run_record_ev "$_m6l_pr" RECORD="$_m6l_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=11 covered=11 residuals=none — residuals filed, not chased

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6l control: on the SAME mutant a residuals=none body still ACCEPTS (rc 0) — the pin killed the filed branch, not the arm"
else
    bad "13m6l could not build the filed-value mutant copy — the pin did not run"
fi

# 13m6m — THE COUNTS MUST IDENTIFY ONE PAIR (#3829 review; measured at `436b0a81`, where vectors 1–4 all
# minted `clean`). The arm read the FIRST `threats=` and the FIRST `covered=` on the line INDEPENDENTLY
# (`command head -n 1`, once per field), so an earlier EQUAL pair shadowed a later contradiction and the
# artifact minted while its OWN marker admitted `covered < threats` — the one fail-open the count-based
# acceptance could open, and the axis the arm's comment names as the guard against a filed list laundering
# an uncovered surface. Each body is ONE line, as the @tsv-escaped capture delivers a pasted cycle-log row.
# Vector 5 is the attribution vector: its two pairs are each OTHER's contradiction (`15/17`, `17/15`), so
# the SETS coincide and a comparison cannot see it — the ambiguity refusal is the only thing that refuses
# it, and 13m6p flips that verdict on a mutant. Vectors 1–4 are the measured pre-fix fail-opens.
_m6m=0
while IFS= read -r _m6m_body; do
    _m6m=$((_m6m + 1)); _m6m_pr=$((424971 + _m6m))
    rm -f "$(Q2 $_m6m_pr)"
    EV_REF="comment:${_m6m_pr}01" run_record_ev "$_m6m_pr" STUB_EVIDENCE_BODY="## Review

${_m6m_body}

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6m vector ${_m6m}: an EARLIER count pair must not shadow the marker's own (rc 3)"
    assert_contains "$RECORD_ERR" "MORE THAN ONE count value" "13m6m vector ${_m6m}: the refusal names the AMBIGUITY, not a contradiction the line never declared"
    [ ! -f "$(Q2 $_m6m_pr)" ] && ok "13m6m vector ${_m6m}: no record minted from an ambiguous count line" || bad "13m6m vector ${_m6m}: minted from an ambiguous count line"
done <<'M6MBODIES'
[ADVERSARIAL-BOUND] cycles=2 threats=9 covered=9 — final: threats=12 covered=9 residuals=#12
[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals=#970; also threats=12 covered=9
covered=17 was last cycle's number; [ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#12
| cycle 1 | threats=17 covered=17 | [ADVERSARIAL-BOUND] cycles=2 threats=17 covered=15 residuals=#12 |
[ADVERSARIAL-BOUND] cycles=2 threats=15 covered=17 threats=17 covered=15 residuals=#12,#14
M6MBODIES

# 13m6n — `residuals= none`, WITH A SPACE after the `=`, is the spelling a human types and the value
# predicate has always allowed it (`[[:space:]]*`) — but the EXTRACTOR was `residuals=[^[:space:]]*`,
# which can never yield a space after the `=`, so the allowance was DEAD CODE and the human spelling was
# refused with `(residuals=)` (#3829 review, measured rc 3). Both directions are pinned: the spaced clean
# value is ACCEPTED, and a spaced NEAR-MISS still refuses — widening the extractor must not widen the
# value grammar with it.
rm -f "$(Q2 424977)"
EV_REF="comment:42497701" run_record_ev 424977 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals= none

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6n residuals= with a SPACE after the = is ACCEPTED (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
rm -f "$(Q2 424978)"
EV_REF="comment:42497801" run_record_ev 424978 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=17 covered=17 residuals= none,#12

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6n a spaced NEAR-MISS value is still refused (rc 3) — the extractor widened, the value grammar did not"

# 13m6o — THE COUNT COMPARISON IS NUMERIC, NOT A STRING COMPARE (#3829 review, measured). `threats=09
# covered=9` is 9 == 9; the string compare refused it with "a declared class was NOT covered", telling an
# honest lane its coverage was incomplete when it was not. The control below (`09` vs `8`) must still
# REFUSE, so normalising the digits cannot become "any two counts are fine".
rm -f "$(Q2 424979)"
EV_REF="comment:42497901" run_record_ev 424979 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] threats=09 covered=9 residuals=none

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6o threats=09 covered=9 is EQUAL (numeric) — accepted (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
rm -f "$(Q2 424980)"
EV_REF="comment:42498001" run_record_ev 424980 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] threats=09 covered=8 residuals=none

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6o threats=09 covered=8 is still a CONTRADICTION — refused (rc 3)"
assert_contains "$RECORD_ERR" "threats=9 but covered=8" "13m6o the contradiction is diagnosed with the NORMALISED numbers (9 vs 8), not the raw strings"

# 13m6p — MUTATION PIN (attribution for the AMBIGUITY refusal, 13m6m). 13m6m asserts that an ambiguous
# count line refuses; this pin proves the ambiguity guard is what refuses 13m6m's vector 5, whose two
# pairs are each other's contradiction so the SETS coincide. Builds a mutant whose guard is disabled and
# requires the identical body to ACCEPT — if it still refuses, that row was passing for another reason.
_m6p_mut="$T/record-review.mut1889e.sh"
command sed 's#^[[:space:]]*if \[ "\$_ab_nt" -gt 1 \] .*$#        if false; then#' "$RECORD" > "$_m6p_mut"
if command grep -q 'if false; then' "$_m6p_mut" && bash -n "$_m6p_mut" 2>/dev/null && ! cmp -s "$_m6p_mut" "$RECORD"; then
    _m6p_pr=424981
    rm -f "$(Q2 $_m6p_pr)"
    EV_REF="comment:${_m6p_pr}01" run_record_ev "$_m6p_pr" RECORD="$_m6p_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=15 covered=17 threats=17 covered=15 residuals=#12,#14

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6p MUTATION: with the ambiguity guard disabled an ambiguous count line is ACCEPTED (rc 0) — 13m6m is load-bearing"
else
    bad "13m6p could not build the ambiguity-guard mutant copy — the pin did not run"
fi

# 13m6q — THE SECOND SPELLING OF THE FILED VALUE: the bare word `filed` (#3829 review, measured at
# `3bef6262`, where it was REFUSED with rc 1). The filed branch demanded a DIGIT in the value — a
# requirement no decision states, none of the enumerated refusal causes names, and the refusal message
# did not name either, so an honest lane met a message listing only conditions it already satisfied.
# It is not hypothetical: `docs/plans/2026-09-21-issue-1321-1322-skill-enforcer-gates.md:463` records
# `threats=13 covered=13 residuals=filed` as that lane's CLEAN exit, and
# `skills/writing-plans/workflow/05-review-handoff.md` instructs every lane to copy that disclosure out
# of the plan doc into the PR body — so the fleet was TOLD to write a spelling this arm refused, and the
# cheap path was rewriting a TRUE disclosure into `none`: the inversion #1889 exists to remove.
# Every acceptance here is BOUNDED like the others: the same word with no counts (vector B), beside a
# contradiction (C), and a near-miss spelling (D) all still REFUSE — the protection is the coverage
# comparison, which is identical for both spellings, so widening the value grammar cannot become "any
# word at all".
rm -f "$(Q2 424982)"
EV_REF="comment:42498201" run_record_ev 424982 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

Every declared threat class C1–C13 is covered by a test; the two residuals are filed and not chased.

[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=filed — bounded by the declared threat surface

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6q the bare word residuals=filed with EQUAL counts is ACCEPTED (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
R13M6Q="$(cat "$(Q2 424982)" 2>/dev/null || true)"
assert_contains "$R13M6Q" '"evidence":"comment:42498201"' "13m6q the accepted artifact is the one the record names"
assert_contains "$R13M6Q" '"mint":"fresh"' "13m6q the bare-word filed form mints a FRESH record"
# Vector A2 — case-insensitivity belongs to BOTH spellings of the filed form (the `none` form and the
# LOWER-CASE marker are already pinned by 13m6b/13m6h; the word must not be the one case-sensitive bit).
rm -f "$(Q2 424983)"
EV_REF="comment:42498301" run_record_ev 424983 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=FILED

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6q residuals=FILED (upper case) is ACCEPTED (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
# Vector B — FAIL-CLOSED boundary: the word's legality rests on the coverage comparison, exactly like a
# numeric list's, so with NO counts it is a cannot-verify (13m6k vector B, one spelling over).
rm -f "$(Q2 424984)"
EV_REF="comment:42498401" run_record_ev 424984 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] residuals=filed — residuals filed, not chased

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6q residuals=filed with NO counts is a cannot-verify — refused (rc 3)"
[ ! -f "$(Q2 424984)" ] && ok "13m6q no record minted from a count-less filed word" || bad "13m6q minted from a count-less filed word"
# Vector C — and it cannot LAUNDER an uncovered surface either: the contradiction refuses before the
# value is judged (13m6k vector C, one spelling over).
rm -f "$(Q2 424985)"
EV_REF="comment:42498501" run_record_ev 424985 STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=11 residuals=filed — residuals filed, not chased

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6q residuals=filed beside covered < threats is a contradiction — refused (rc 3)"
[ ! -f "$(Q2 424985)" ] && ok "13m6q no record minted from a filed word admitting an uncovered class" || bad "13m6q minted from a filed word beside an uncovered class"
# Vector D — THE WIDENING DID NOT LEAK. Only the EXACT word (up to its own delimiter) is the filed
# form: a word that merely CONTAINS it, and a digit-free value that asserts nothing, both refuse.
_m6q=0
while IFS= read -r _m6q_val; do
    _m6q=$((_m6q + 1)); _m6q_pr=$((424985 + _m6q))
    rm -f "$(Q2 $_m6q_pr)"
    EV_REF="comment:${_m6q_pr}01" run_record_ev "$_m6q_pr" STUB_EVIDENCE_BODY="## Review

[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=${_m6q_val}

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6q near-miss filed value '${_m6q_val}' is REFUSED (rc 3) — the word is matched exactly"
done <<'M6QVALUES'
filed-off
some
yes
unknown
done
M6QVALUES

# 13m6r — MUTATION PIN (attribution for the bare-word branch, and the control that keeps it honest).
# 13m6q asserts the word is accepted; this pin proves THAT branch (`(ii-c)`) is what accepts it — with
# the branch replaced by `:` the identical body must REFUSE — and, the CONTROL, a NUMERIC filed list on
# the SAME mutant must still ACCEPT, so the pin cannot pass by having killed the whole filed branch.
# The `sed` pattern carries the branch's own literal (`filed[,.:;)]*$`) and is asserted to bind EXACTLY
# ONCE and to stay parseable, so a refactor that moves the line reddens HERE instead of silently
# letting this pin test unmutated code (#3442).
_m6r_mut="$T/record-review.mut1889f.sh"
command sed 's#^[[:space:]]*if \[ "\$_ab_ok" -ne 1 \].*\^\[\[:space:\]\]\*filed.*$#            :#' "$RECORD" > "$_m6r_mut"
_m6r_binds=$(command diff "$RECORD" "$_m6r_mut" 2>/dev/null | command grep -c '^< ' || true)
if [ "${_m6r_binds:-0}" = "1" ] && ! command grep -qF 'filed[,.:;)]*' "$_m6r_mut" && bash -n "$_m6r_mut" 2>/dev/null \
   && ! cmp -s "$_m6r_mut" "$RECORD"; then
    _m6r_pr=424991
    rm -f "$(Q2 $_m6r_pr)"
    EV_REF="comment:${_m6r_pr}01" run_record_ev "$_m6r_pr" RECORD="$_m6r_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=filed

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "3" "13m6r MUTATION: with the bare-word branch disabled residuals=filed is REFUSED (rc 3) — 13m6q is load-bearing"
    _m6r_pr=424992
    rm -f "$(Q2 $_m6r_pr)"
    EV_REF="comment:${_m6r_pr}01" run_record_ev "$_m6r_pr" RECORD="$_m6r_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=#1269

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6r control: on the SAME mutant a NUMERIC filed list still ACCEPTS (rc 0) — the pin killed the word branch, not the filed branch"
else
    bad "13m6r could not build the bare-word mutant copy (binds='${_m6r_binds:-?}') — the pin did not run"
fi

# 13m6s — THE COUNT FIELD NEEDS A LEFT BOUNDARY (#3829's SECOND review; measured at `39455bdd`). The
# extractor was an UNANCHORED substring, so `grep -oiE 'covered=[0-9]+'` matched INSIDE `uncovered=13`
# and `not-covered=13`: a marker that declares every class UNCOVERED —
# `threats=13 uncovered=13 residuals=filed` — read `covered='13'`, compared equal to `threats`, and
# minted `clean`. That is the single fail-open the contradiction guard exists to prevent, and it was
# reachable with EITHER filed spelling (`residuals=#1269` too), so it defeated the whole arm. The
# mirror was a false refusal: `covered=13 uncovered=0` was read as two covered values and rejected as
# "MORE THAN ONE count value" — the honest lane told it had declared a count pair it never wrote.
# Both directions are pinned, and 13m6t makes the anchoring load-bearing.
rm -f "$(Q2 424993)"
EV_REF="comment:42499301" run_record_ev 424993 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] cycles=2 threats=13 uncovered=13 residuals=filed — bounded by the declared threat surface

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6s uncovered=<n> is NOT coverage evidence — a marker admitting uncovered classes is refused (rc 3)"
[ ! -f "$(Q2 424993)" ] && ok "13m6s no record minted from a marker that declares classes UNCOVERED" || bad "13m6s minted from a marker declaring every class UNCOVERED"
rm -f "$(Q2 424994)"
EV_REF="comment:42499401" run_record_ev 424994 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] cycles=2 threats=13 not-covered=13 residuals=#1269 — bounded by the declared threat surface

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "3" "13m6s not-covered=<n> is not coverage evidence either — refused with the NUMERIC spelling too (rc 3)"
[ ! -f "$(Q2 424994)" ] && ok "13m6s no record minted from not-covered=<n>" || bad "13m6s minted from not-covered=<n>"
# The MIRROR: an honest disclosure that says ZERO uncovered beside a real equal pair must ACCEPT —
# before the anchor it was refused as an ambiguity the line never declared.
rm -f "$(Q2 424995)"
EV_REF="comment:42499501" run_record_ev 424995 STUB_EVIDENCE_BODY="## Review — THREAT SURFACE COVERED

[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 uncovered=0 residuals=filed

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "13m6s covered=<n> uncovered=0 is a CLEAN disclosure, not an ambiguity — accepted (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"

# 13m6t — MUTATION PIN (attribution for the LEFT BOUNDARY). 13m6s asserts that `uncovered=` is not
# coverage evidence; this pin proves the BOUNDARY is what refuses it — with the boundary emptied the
# identical body must ACCEPT — and the control, on the SAME mutant, a plain equal-count marker must
# still ACCEPT (the pin broke the boundary, not the arm). The boundary is ONE named constant
# (`_ab_lb`), which is what makes this a one-token mutation rather than a bracket-escaping exercise:
# the first draft of this pin tried to `sed` the bracket expression itself and matched 69 lines.
_m6t_mut="$T/record-review.mut1889g.sh"
command sed 's#^[[:space:]]*_ab_lb=.*$#        _ab_lb=#' "$RECORD" > "$_m6t_mut"
_m6t_binds=$(command diff "$RECORD" "$_m6t_mut" 2>/dev/null | command grep -c '^< ' || true)
if [ "${_m6t_binds:-0}" = "1" ] && command grep -qF "_ab_lb='(^|" "$RECORD" \
   && bash -n "$_m6t_mut" 2>/dev/null && ! cmp -s "$_m6t_mut" "$RECORD"; then
    _m6t_pr=424996
    rm -f "$(Q2 $_m6t_pr)"
    EV_REF="comment:${_m6t_pr}01" run_record_ev "$_m6t_pr" RECORD="$_m6t_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=13 uncovered=13 residuals=filed

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6t MUTATION: with the LEFT BOUNDARY removed uncovered=13 mints clean (rc 0) — 13m6s is load-bearing"
    _m6t_pr=424997
    rm -f "$(Q2 $_m6t_pr)"
    EV_REF="comment:${_m6t_pr}01" run_record_ev "$_m6t_pr" RECORD="$_m6t_mut" \
        STUB_EVIDENCE_BODY="[ADVERSARIAL-BOUND] cycles=2 threats=13 covered=13 residuals=filed

$VACUITY_BLOCK"
    assert_eq "$RECORD_RC" "0" "13m6t control: on the SAME mutant a plain equal-count marker still ACCEPTS (rc 0) — the pin broke the anchor, not the arm"
else
    bad "13m6t could not build the unanchored-extractor mutant (binds='${_m6t_binds:-?}') — the pin did not run"
fi

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
EV_REF="review:42476001" run_record_ev 424760 STUB_EVIDENCE_BODY="Reviewed the diff.

$VACUITY_BLOCK" STUB_REVIEW_STATE="COMMENTED"
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
    # ⛔ ATTRIBUTABLE, NOT MERELY RED (#3442 rule 2 applied to this suite's own arm). Since #3442 there
    # are TWO arms that can refuse an empty-body review — the state veto above and the non-vacuity arm
    # at the end — so an exit-code-only assertion would stay green on a mutant that deleted the state
    # veto. Naming the state in the refusal is what keeps THIS arm pinning the state.
    case "$RECORD_ERR" in
      *"is a $_q2_state review"*) ok "13q2 …and the refusal NAMES the $_q2_state state (the state veto, not the non-vacuity arm)" ;;
      *) bad "13q2 …the refusal did not name the $_q2_state state: $(printf '%.160s' "$RECORD_ERR")" ;;
    esac
    [ ! -f "$(Q2 $_q2_pr)" ] && ok "13q2 no record written for an empty-body $_q2_state review" || bad "13q2 wrote a record for an empty-body $_q2_state review"
done
rm -f "$(Q2 424764)"
EV_REF="review:42476401" run_record_ev 424764 STUB_EVIDENCE_BODY="" STUB_REVIEW_STATE="APPROVED"
# ⛔ #3442 CHANGES THE CONTROL, AND THE MESSAGE NOW CLAIMS ONLY WHAT IT CAN PROVE (fresh-context
# review of this change, P2-C). An EMPTY body can no longer be clean evidence (a clean claim must carry
# the attribution block), so these two controls now assert the NON-VACUITY refusal. They do NOT claim
# to pin the empty-field parse — an earlier revision said they did, and that claim was unfalsifiable:
# if the `%%`/`#` split regressed and `body` became "APPROVED" (state empty), the non-vacuity arm
# would emit the SAME text, so the assertion would be green in both worlds. The parse IS pinned — by
# the CHANGES_REQUESTED/DISMISSED/PENDING loop above, whose assertion names the STATE (only the state
# arm emits that word), so a collapsed parse reddens it.
assert_eq "$RECORD_RC" "3" "13q2 control: an empty-body APPROVED review is refused by the NON-VACUITY arm (rc 3)"
case "$RECORD_ERR" in *"MUTATION ATTRIBUTION"*) ok "13q2 …and the refusal names the non-vacuity arm (the state arm never fires for APPROVED)" ;; *) bad "13q2 …the refusal did not name the non-vacuity arm: $(printf '%.160s' "$RECORD_ERR")" ;; esac
rm -f "$(Q2 424765)"
EV_REF="review:42476501" run_record_ev 424765 STUB_EVIDENCE_BODY="" STUB_REVIEW_STATE="COMMENTED"
assert_eq "$RECORD_RC" "3" "13q2 control: an empty-body COMMENTED review is refused by the NON-VACUITY arm (rc 3)"
case "$RECORD_ERR" in *"MUTATION ATTRIBUTION"*) ok "13q2 …and that refusal names the non-vacuity arm too" ;; *) bad "13q2 …the COMMENTED refusal did not name the non-vacuity arm" ;; esac

# ── 13v — agent-infra#3442: THE NON-VACUITY ARM, DRIVEN, WITH ITS OWN MUTANT ────────────────────
# The claim: a FRESH `clean` verdict cannot be minted over a review artifact that never says which
# mutant reddens which assertion. Three arms (admit / exempt / refuse) and then the mutant that
# reverts the fix, so the suite proves the arm can FAIL rather than asserting that a string exists.
echo "── 13v. the non-vacuity contract on the record path (#3442) ──────────────────"
VACU_POS=424780
rm -f "$(Q2 $VACU_POS)"
EV_REF="comment:${VACU_POS}01" run_record_ev "$VACU_POS"
assert_eq "$RECORD_RC" "0" "13v1 an artifact carrying the attribution table MINTS clean (rc 0) — and this proves the @tsv un-escape, since the stub always escapes newlines"
assert_contains "$(cat "$(Q2 $VACU_POS)" 2>/dev/null)" '"evidence":"comment:'"${VACU_POS}"'01"' "13v1 …and the record names that artifact"
VACU_NONE=424781
rm -f "$(Q2 $VACU_NONE)"
EV_REF="comment:${VACU_NONE}01" run_record_ev "$VACU_NONE" STUB_EVIDENCE_BODY="### Code review

No issues found — the diff is docs-only.

## MUTATION ATTRIBUTION
NO NEW ASSERTIONS: docs-only, the diff touches docs/ops/*.md and no executable assertion."
assert_eq "$RECORD_RC" "0" "13v2 the NO NEW ASSERTIONS exemption is REACHABLE (rc 0) — a docs-only review is not deadlocked by this gate"
VACU_BAD=424782
rm -f "$(Q2 $VACU_BAD)"
EV_REF="comment:${VACU_BAD}01" run_record_ev "$VACU_BAD" STUB_EVIDENCE_BODY="### Code review

No issues found. Checked for bugs and guidance compliance. I read the new test and it looks right.

## MUTATION ATTRIBUTION
I thought about whether the new assertion could fail."
assert_eq "$RECORD_RC" "3" "13v3 a clean claim whose attribution block states NO mutant is REFUSED (rc 3) — 'I thought about it' is not an attribution"
[ ! -f "$(Q2 $VACU_BAD)" ] && ok "13v3 no record minted from a prose-only attribution" || bad "13v3 minted a record from a prose-only attribution"
case "$RECORD_ERR" in *"MUTATION-"*) ok "13v3 …and the refusal NAMES the missing shape (MUTATION-*), so the remedy is legible" ;; *) bad "13v3 …the refusal did not name the missing shape: $(printf '%.160s' "$RECORD_ERR")" ;; esac
# ⛔ MUTATE THE SHIPPED FILE, NOT THE TEST — the §13b idiom one screen up. The mutant neuters the one
# call that decides, which is exactly the pre-#3442 code: `verify_review_evidence` then has no
# question to ask about non-vacuity, and 13v3's refusal must become an ACCEPTANCE.
VACU_MUT="$T/record-review-nonvacuity-mutant.sh"
# ⛔ THE MUTANT LIVES BESIDE A COPY OF THE VALIDATOR, ON PURPOSE. `verify_review_evidence` resolves
# `brief-gate.sh` from four homes and REFUSES when none of them has it (a cannot-verify is never a
# pass), so a mutant in a bare temp dir would fail closed for the WRONG reason and the arm below would
# report the fail-closed path instead of the removed check. The symlink supplies the real validator via
# the `$SELF`-adjacent home — which also exercises the FLAT (installed `$O`) shape of that ladder.
ln -sfn "$SCRIPT_DIR/orchestrator-harness/brief-gate.sh" "$T/brief-gate.sh"
# …and the recorder resolves `lib/diff-normalize.py` from ITS OWN directory (DIFF_NORMALIZER) in the
# mode that runs the whole script. This arm does not need that (see the seam below), but the symlink
# stays: the next reader who drives the mutant end-to-end must not hit a failure that has nothing to
# do with the arm under test.
ln -sfn "$SCRIPT_DIR/lib" "$T/lib"
sed 's|^\(  ma_miss="\$(printf .*--mutation-missing - 2>/dev/null)".*\)$|  ma_miss=""  # MUTANT: the pre-3442 code, which asked nothing|' "$RECORD" > "$VACU_MUT"
if cmp -s "$RECORD" "$VACU_MUT"; then bad "13v MUTANT: the sed anchor no longer matches — the mutation is not applied, so the arm below would prove nothing"; else ok "13v MUTANT: the non-vacuity check is really removed from the shipped recorder"; fi
bash -n "$VACU_MUT" && ok "13v MUTANT: the mutant still parses (it fails for the contract, not for a syntax error)" || bad "13v MUTANT: the mutant does not parse"
# ⛔ THE SEAM IS `verify_review_evidence` ITSELF, NOT THE WHOLE RECORDER, and that is a deliberate
# choice about ATTRIBUTION (#3442 rule 2). Driving `record-review.sh` end-to-end adds the diff-digest
# read, the marker post and the record write between the mutation and the observable, and any of those
# returning non-zero would look exactly like "the mutation did not flip the arm". The file is SOURCED
# here — its main block is guarded by `BASH_SOURCE == $0` precisely so a test can do this — and the
# function that decides is called directly, so the only thing that differs between the two rows is the
# mutation. Both rows use the SAME fixture, and the fixture is the one 13v3 refused.
VACU_PRE=424783
export STUB_EVIDENCE_BODY="### Code review

No issues found.

## MUTATION ATTRIBUTION
I thought about whether the new assertion could fail."
run_verify_direct() { # <script-to-source> -> the evidence gate's rc
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR=$VACU_PRE STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        rc=0
        bash -c '. "$1" >/dev/null 2>&1; REPO="daniel-ospina/agent-infra"; PR="$2"; SHA="$3"; verify_review_evidence "comment:$2"01 "$3" clean >/dev/null' \
            _ "$1" "$VACU_PRE" "$SHA" 2>/dev/null || rc=$?
        printf '%s' "$rc"
    )
}
VACU_SHIPPED_RC="$(run_verify_direct "$RECORD")"
assert_eq "$VACU_SHIPPED_RC" "1" "13v MUTANT control: the SHIPPED gate refuses the prose-only attribution at the function (rc $VACU_SHIPPED_RC)"
VACU_MUT_RC="$(run_verify_direct "$VACU_MUT")"
assert_eq "$VACU_MUT_RC" "0" "13v ⛔ MUTATION: with the non-vacuity check removed, the SAME fixture is ADMITTED (rc $VACU_MUT_RC) — so 13v3 reddens ON THIS ARM, not on an unrelated one"
unset STUB_EVIDENCE_BODY
rm -f "$(Q2 $VACU_PRE)"
# ── 13v4 — FOUND-BUT-UNANSWERABLE IS A CANNOT-VERIFY (fresh-context review of this change, P1 Y). ──
# The first cut read the validator's STDOUT as the verdict and never its STATUS, so a `brief-gate.sh`
# that predates `--mutation-missing` — the pre-#3442 CLI answers `printf usage >&2; exit 78` — produced
# EMPTY stdout, which read as "the artifact is fine" and minted the record. This arm puts a STALE gate
# in the mutant's own `$SELF`-adjacent home (the first rung of the recorder's ladder) and drives the
# shipped caller, so the assertion is on the recorder, not on a hand-written predicate.
# ⛔ A PLAIN COPY OF THE RECORDER LIVES IN `$T`, so the stale gate is its FIRST resolution rung. The
# shipped `$RECORD` keeps `scripts/` as its first rung — where the REAL gate sits — so driving it would
# test the real validator and the stale one would never be consulted (a fixture that cannot reach the
# state it claims to test).
cp "$RECORD" "$T/record-review-plain.sh"
printf '#!/bin/sh\ncase "$1" in --check|--section|--line|--missing) exit 0;; *) echo "usage: $0 …" >&2; exit 78;; esac\n' > "$T/brief-gate.stale"
rm -f "$T/brief-gate.sh"
ln -sfn "$T/brief-gate.stale" "$T/brief-gate.sh"
chmod +x "$T/brief-gate.stale"
export STUB_EVIDENCE_BODY="Reviewed the diff; no issues found."
VACU_STALE_RC="$(run_verify_direct "$T/record-review-plain.sh")"
assert_eq "$VACU_STALE_RC" "1" "13v4 a STALE validator (one that predates --mutation-missing, exit 78) makes the recorder REFUSE, not mint (rc $VACU_STALE_RC) — a cannot-verify is never a pass"
# …and the mutant that drops the status check is what re-opens the fail-open, so the arm above is
# load-bearing on the line it names and not on the resolution ladder.
VACU_RCMUT="$T/record-review-rc-mutant.sh"
sed 's/^  if \[ "$ma_rc" -ne 0 \]; then$/  if false; then/' "$RECORD" > "$VACU_RCMUT"
if cmp -s "$RECORD" "$VACU_RCMUT"; then bad "13v4 MUTANT: the sed anchor no longer matches — the status check is not removed, so the arm above proves nothing"; else ok "13v4 MUTANT: the status check is really removed from the shipped recorder"; fi
VACU_RC_RC="$(run_verify_direct "$VACU_RCMUT")"
assert_eq "$VACU_RC_RC" "0" "13v4 ⛔ MUTATION: with the status check removed, the SAME stale validator MINTS (rc $VACU_RC_RC) — the fail-open the review found, reproduced"
unset STUB_EVIDENCE_BODY
rm -f "$T/brief-gate.sh"; mv "$T/brief-gate.real" "$T/brief-gate.sh" 2>/dev/null || ln -sfn "$SCRIPT_DIR/orchestrator-harness/brief-gate.sh" "$T/brief-gate.sh"
# POLARITY CONTROL, and it is an EXISTING arm rather than a new one: §20.0 mints a `not-clean` record
# over an artifact that carries NO attribution block ('## Review — NOT CLEAN …', no table). A negative
# verdict legitimately has no kill table, so this arm is what reddens if the non-vacuity check ever
# leaks into the negative path. Named here so the polarity skip is a DECISION with an assertion, not
# an accident a later reader has to infer from the code's statement order.

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
    local rcfile="$T/rc633" errfile="$T/err633" cap="$T/cap633" outfile="$T/out633"
    # RR633_SCRIPT lets a mutation pin run the SAME vector against a mutated copy
    # of the recorder (the #10177 pin needs it: a rule that cannot be removed in a
    # copy cannot be shown to be load-bearing).
    local rec="${RR633_SCRIPT:-$RECORD}"
    : > "$LOG"; : > "$cap"; : > "$outfile"; rm -f "$errfile"
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        export STUB_BODY="${STUB_BODY:-PR body}"
        export STUB_CAPTURE="$cap"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        export STUB_CHECK_RUNS="$cruns"
        export STUB_CHECK_RUNS_FAIL="${STUB_CHECK_RUNS_FAIL:-0}"
        export STUB_RERUN_FAIL="${STUB_RERUN_FAIL:-0}"
        export STUB_PATCH_FAIL="${STUB_PATCH_FAIL:-0}"
        # agent-infra#3168: the durable comment channel's knobs. Passed through so a
        # vector can serve an admitted comment set, model the `gh api` read failure
        # (a NON-EMPTY error body on STDOUT plus a non-zero exit), and capture the
        # posted comment body for the idempotency vector.
        export STUB_COMMENT_BODIES="${STUB_COMMENT_BODIES:-}"
        # #3168 re-review P3: the ENVELOPE fixture the stub applies the caller's own
        # `--jq` to. Without it the admission constant could only be pinned as SOURCE
        # TEXT (measured: the drop-the-filter mutant stayed GREEN).
        export STUB_COMMENT_JSON="${STUB_COMMENT_JSON:-}"
        export STUB_COMMENT_FAIL="${STUB_COMMENT_FAIL:-0}"
        export STUB_COMMENT_POST_FAIL="${STUB_COMMENT_POST_FAIL:-0}"
        export STUB_COMMENT_CAPTURE="${STUB_COMMENT_CAPTURE:-}"
        export STUB_BODY_FAIL="${STUB_BODY_FAIL:-0}"
        export STUB_BODY_FAIL_TEXT="${STUB_BODY_FAIL_TEXT:-}"
        # Review finding 3: an UNSIGNED marker (no key) must not fire the rerun.
        # The runner passes the caller's gate key through so a vector can unset
        # it (the suite exports a deterministic key at the top).
        export AI_REVIEW_GATE_KEY="${AI_REVIEW_GATE_KEY-}"
        # The check-name override is passed through for the same reason.
        export AI_REVIEW_GATE_CHECK_NAME="${AI_REVIEW_GATE_CHECK_NAME-}"
        [ -n "${STUB_HEAD_SHA:-}" ] && export STUB_HEAD_SHA
        rc=0
        bash "$rec" "$pr" "$sha" clean "daniel-ospina/agent-infra" "$@" $EV_ARGS 2>"$errfile" 1>"$outfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null || true
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
    RECORD_CAP633="$(cat "$cap" 2>/dev/null || true)"
    # STDOUT, captured separately (#3168 review cycle 4). The durable channel's
    # SUCCESS line goes to stdout and NOTHING inspected it — so restoring the old
    # "(body mirror retained: …)" tail, which asserts a body-channel state this
    # function cannot know, left the suite at PASS=936 FAIL=0.
    RECORD_OUT633="$(cat "$outfile" 2>/dev/null || true)"
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

# 14.1c THE LINE-ANCHORED PRESENCE PREDICATE (agent-infra#3168). ⛔ THE ATTRIBUTION IS
#     PART OF THE PIN — and it was WRONG twice before this correction (#3168 re-review
#     finding 2), so state it exactly: THIS DIFF ANCHORS **NO** SITE in the recorder.
#     All four `grep -qxF` sites are ALREADY anchored on main
#     (`git show bd1b205d:scripts/record-review.sh | grep -n 'grep -qxF'` — the sha is NAMED because
#     `origin/main` moves and a bare "main :NNNN" rots the moment it does
#     → :2482 :4186 :6501 :6613, plus a comment mention at :2356) and the
#     same four PREDICATE sites are at head
#     (`grep -n 'grep -qxF' scripts/record-review.sh` prints all four PREDICATE lines at head —
#     CITE-CHECK: :2736 :4462 :6832 :7006, plus a comment mention at :2605; `14.1c-CITE` below
#     re-derives these numbers, so they cannot rot silently): in #3168's diff the only
#     hunk at `post_marker()` (:2714) ADDS A COMMENT — this PR does not touch
#     `post_marker()` at all — and the
#     predicate line beside it (CITE-CHECK: :2736) is CONTEXT, not a change.
#     WHAT THE VECTOR BELOW ACTUALLY PINS: the BODY-APPEND site
#     (`if ! grep -qxF -- "$MARKER" <<<"$BODY"`; on main at bd1b205d :6501 — at head CITE-CHECK: :6832). It is a
#     MAIN-REGRESSION pin — reverting this PR leaves 14.1c GREEN, and 14.10f is a
#     main-regression pin for the same reason. Keeping them is right (main's
#     anchoring should not silently regress); calling them evidence about this diff
#     was not. It matches
#     the gate's own `^…$` admission of a body marker. A body that merely
#     CITES the marker mid-line is the discriminating case: unanchored `-qF` read
#     it as PRESENT, so the recorder PATCHed nothing and set MARKER_PRESENT=1 on
#     a line the gate rejects — the evidence never reached the channel the gate
#     reads, and the stale pre-evidence run was not re-run either, so a correctly
#     reviewed PR stayed red with its verdict nowhere admissible. 14.1 is this
#     vector's NEGATIVE CONTROL (the marker alone on its line ⇒ no PATCH): the two
#     differ ONLY in anchoring, so a revert to `-qF` reddens 14.1c while 14.1
#     stays green — which is what makes the pair pin the predicate rather than
#     the fixture. The marker text is SEEDED from the recorder's own post (never
#     hand-written) so its diff=/sig= contract cannot drift from the script's.
#
# 14.1c-CITE ⛔ A CITATION MUST RE-DERIVE — SO THE SENTENCE ABOVE IS A TEST, NOT A NOTE
#     (agent-infra#3712 re-review). The comments above print head line numbers as the
#     evidence that a reader can check the claim. Prose rots silently: the comment block
#     added above the persist site moved BOTH body-presence predicates by +9 and the numbers
#     beside them stayed put — so the sentence went on *reading* correct while pointing at
#     prose (MEASURED, one commit per pair: the two body-presence PREDICATES sat at
#     `:6625` / `:6770` at `dc7e3ae99`, `:6634` / `:6779` at `921109de2` and `:6639` / `:6796` at
#     `17551325e` as comment blocks were added above them, while the CITES beside them still read
#     `:6625` / `:6770` at all three — that divergence IS the rot this paragraph describes — and at
#     this head the predicates are `:6832` / `:7006` — CITE-CHECK: :6832 :7006 — re-derived by the
#     guard below, like every other head cite of a predicate). One
#     lane's response was to delete the numbers — which removes the rot but also removes the
#     reader's target. Both intents are kept here: the number stays, and it is CHECKED.
#     Every head number printed FOR A BODY-PRESENCE PREDICATE is TAGGED `CITE-CHECK:`; the tagged
#     numbers are parsed back OUT, each must land on a `grep -qxF` line, and the deduped set must
#     EQUAL the executing sites — so a predicate added without a citation reddens too, and a stale
#     number REDDENS instead of waiting for a reviewer. ⛔ SCOPE: cites for anything else are NOT
#     tagged and NOT checked — tagging one REDDENS, since membership is set EQUALITY, not a superset.
#     ⛔ WHAT IS OUT OF ITS REACH, measured: an UNTAGGED head number elsewhere in this file is
#     invisible (mutating one to a nonexistent line leaves all four assertions green), every head
#     number in `tests/record-review/run.sh` is never read, and a RANGE (`:6537-6549`) cannot be
#     tagged at all because the tag parser reads a run of `:NNNN` tokens and a dash ends it. Those
#     are still re-derived BY HAND each round: this guard makes the tagged cites un-rottable, it
#     does not make the rest safe.
QR_SELF="$SCRIPT_DIR/record-review.test.sh"
QR_CITE_SITES="$(command grep -n 'grep -qxF' "$RECORD" | command grep -vE '^[0-9]+: *#' \
    | cut -d: -f1 | sort -un | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
# ⛔ THE PATTERNS NAME NO BACKTICK — 20h48b scans double-quoted command substitutions for one, and
# it CAUGHT the first draft of this guard. The tag is the anchor, so the phrasing around a number
# can be reworded freely; only the tag and the numbers after it are contractual.
QR_CITED="$(command grep -E '^[[:space:]]*#.*CITE-CHECK:' "$QR_SELF" \
    | sed -n 's/.*CITE-CHECK: *\(:[0-9][0-9 :]*\).*/\1/p' \
    | tr -d ':' | tr -s ' ' | tr '\n' ' ' | tr ' ' '\n' | sort -un | tr '\n' ' ' \
    | sed 's/^ *//; s/ *$//')"
# Every prerequisite below proves its capture is LIVE, so no assertion can pass on an empty parse.
assert_eq "$([ -n "$QR_CITE_SITES" ] && echo live || echo dead)" "live" \
    "14.1c-CITE prerequisite: the recorder has identifiable executing grep -qxF sites"
assert_eq "$([ -n "$QR_CITED" ] && echo live || echo dead)" "live" \
    "14.1c-CITE prerequisite: the CITE-CHECK tags parse (the citation is still tagged)"
assert_eq "$QR_CITED" "$QR_CITE_SITES" \
    "14.1c-CITE the head sites the comments print ARE the recorder's grep -qxF sites"
QR_STALE=""
for _qr_n in $QR_CITED; do
    command grep -qF -- 'grep -qxF' <<<"$(command sed -n "${_qr_n}p" "$RECORD")" \
        || QR_STALE="$QR_STALE :$_qr_n"
done
assert_eq "$QR_STALE" "" \
    "14.1c-CITE every tagged line number IS a grep -qxF line (stale:$QR_STALE)"

QB_PR=424339
QB_SEED="$(seed_marker_body "$QB_PR")"
QB_LINE=""
if [ -n "$QB_SEED" ]; then
    QB_LINE="$(printf '%s\n' "$QB_SEED" | grep -E '^review recorded: ' | head -1 || true)"
fi
if [ -n "$QB_LINE" ]; then
    ok "14.1c the seed produced a marker line to quote (prerequisite)"
else
    bad "14.1c no marker line in the seeded body — the anchor vector would judge a fixture, not the predicate"
fi
# Same bytes, NOT alone on their line: a lane citing the attestation in prose.
QB_BODY="A lane cited the attestation inline: $QB_LINE — see above.
"
STUB_BODY="$QB_BODY" run_record_633 "$QB_PR" "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":901}]'
if grep -qF -- "-X PATCH" "$LOG"; then
    ok "14.1c a mid-line marker does not suppress the append (anchored presence test)"
else
    bad "14.1c a mid-line marker SUPPRESSED the append — the unanchored -qF is back (log: $(cat "$LOG"))"
fi
QB_NEWBODY="$(printf '%s' "$RECORD_CAP633" | jq -r '.body // empty' 2>/dev/null || true)"
if [ -n "$QB_LINE" ] && grep -qxF -- "$QB_LINE" <<<"$QB_NEWBODY"; then
    ok "14.1c …and the posted body carries the marker on a line of its OWN (gate-admissible)"
else
    bad "14.1c the posted body carries no anchored marker line (capture: $QB_NEWBODY)"
fi
# The OTHER half of the same predicate: MARKER_PRESENT is re-read from the body
# AFTER the post (BODY_NOW). ⛔ THIS PINS THE RE-READ, NOT A HAZARD — say what was
# MEASURED: the anchoring of the MARKER_PRESENT site cannot be discriminated by
# ANY fixture here. A successful ANCHORED append always leaves `$MARKER` alone on
# a line in BODY_NOW, and the pre-fix `-qF` is strictly MORE permissive, so
# reverting ONLY that site keeps this vector green (measured: PASS=908 FAIL=0 with
# that one site reverted) — the same reason 14.1 above cannot catch a one-sided
# revert either; assertions 1–2 are what pin the append decision, which is the one
# that can lose evidence. What this assertion does catch is the re-read being
# dropped: without `BODY_NOW="$NEWBODY"` the marker is posted and the recorder
# still believes it absent, so the #633 rerun is skipped on a head that has it.
if grep -qF -- "actions/jobs/901/rerun" "$LOG"; then
    ok "14.1c MARKER_PRESENT sees the appended line — the stale run is re-run, not skipped"
else
    bad "14.1c the re-read did not see the appended marker ⇒ the stale run was never re-run (log: $(cat "$LOG"))"
fi

# 14.1d THE DURABLE COMMENT CHANNEL (agent-infra#1224 producer half, #3168).
#      NO assertion pinned this channel: neutering the POST left the suite at
#      PASS=908 FAIL=0, so the two arms that can LOSE or DUPLICATE the evidence —
#      the dedup read and the read-FAILURE arm — were unpinned. Each vector below
#      reddens when its arm is removed, and each asserts the TRANSPORT (a POST in
#      the stub log), never the exit code alone.
# ⛔ ONE PRODUCER (merge resolution). The channel has exactly ONE writer —
# `post_review_evidence_comment` — so every fixture below feeds it in the GATE'S
# OWN FRAME `<assoc>\x1f<body>\x1e` (`STUB_COMMENTS`), which is what its `--jq`
# admission predicate consumes. A bare-body fixture never reaches that predicate:
# measured, it posted anyway and the idempotency pin passed for the wrong reason.
DC_PR=424341
DC_CRUNS='[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":902}]'
dc_posts() { command grep -cF -- "-X POST repos/daniel-ospina/agent-infra/issues/$1/comments" "$LOG" 2>/dev/null || true; }
# (a) a signed record publishes the marker to the comment channel exactly once.
STUB_COMMENT_BODIES="" STUB_COMMENT_CAPTURE="$T/ccap_a" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$(dc_posts "$DC_PR")" "1" "14.1d a signed record posts the marker to the durable comment channel exactly once"
DC_MARKER="$(jq -r '.body // empty' "$T/ccap_a" 2>/dev/null || true)"
if [ -n "$DC_MARKER" ]; then
    ok "14.1d the posted comment carries a body (prerequisite for the idempotency vector)"
else
    bad "14.1d the comment POST captured no body — the idempotency vector would judge a fixture, not the code"
fi
# (b) IDEMPOTENCY: an admitted comment already carrying this exact marker ⇒ no POST.
STUB_COMMENTS="OWNER"$'\037'"$DC_MARKER"$'\036' STUB_COMMENT_CAPTURE="$T/ccap_b" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$(dc_posts "$DC_PR")" "0" "14.1d a comment already carrying the marker is NOT duplicated (idempotency)"
# (b2) ⛔ THE DEDUP DEMANDS THE **WHOLE BODY** — and (b) CANNOT see it (fresh-review
#      finding 1). (b) serves the marker as the WHOLE comment body, which satisfies both
#      whole-body equality and a substring test, so (b) alone cannot discriminate.
#      ⛔ THE MUTANT NAMED HERE USED TO BE WRONG (#3168 re-review finding 2): this row
#      previously claimed "`-qxF`->`-qF` at the dedup read left the suite at
#      PASS=921 FAIL=0". THERE IS NO GREP AT THE DEDUP READ — not anchored, not
#      unanchored: the loop compares whole bodies with `[ "$_body" = "$marker" ]`
#      (scripts/record-review.sh:2468 — `grep -n '\[ "$_body" = "$marker" \]'`), so that mutant does not exist and could not
#      have been measured. The mutant that actually makes (b2) meaningful is replacing
#      that equality with a SUBSTRING test (`case "$_body" in *"$marker"*)`): it
#      reddens (b2) — which expects 1 POST and would get 0.
#      That is not a style flag: under a substring test, any admitted comment that
#      merely CITES or QUOTES the marker mid-line satisfies the dedup on EVERY later
#      run, so the channel never posts again — the durable copy is permanently dead —
#      and nothing reds. It is the same asymmetry the BODY channel is pinned for at
#      14.10f (which is likewise a MAIN-regression pin), on the durable channel.
#      The gate admits a comment only when the marker is ALONE IN THE BODY, so the
#      producer must not treat a quoting comment as "already posted".
# ⛔ SAME PR AS (b), ON PURPOSE. The marker embeds `reviews/<pr>.json`, so a body
#    quoting ANOTHER PR's marker cannot match this run's marker under EITHER flag —
#    that vector passes while proving nothing (measured: the first draft of this
#    very arm used $DC_PR+1 and stayed GREEN under the `-qF` mutant). Reusing
#    $DC_PR makes (b) and (b2) a non-vacuous PAIR on one PR and one marker: the
#    same run that posts 0 for an EXACT whole-body match must post 1 for a body
#    that merely CONTAINS the marker, so neither arm can pass on a short-circuit.
STUB_COMMENTS="OWNER"$'\037'"see the record below — $DC_MARKER — and that is all"$'\036' \
    STUB_COMMENT_CAPTURE="$T/ccap_b2" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$(dc_posts "$DC_PR")" "1" \
    "14.1d a comment that merely QUOTES the marker mid-line does NOT satisfy the dedup (line-anchored, like the gate's admission)"
if [ -s "$T/ccap_b2" ]; then
    ok "14.1d …and the post it makes carries a body (the vector is not judging an empty capture)"
else
    bad "14.1d the anchored-dedup vector captured no POST body — it would pass on a post that never happened"
fi
# (b4) ⛔ THE FRAME EXPRESSION IS **EXECUTED**, NOT MERELY PRESENT (#3168 re-review P2).
#      The read hands the gate's own expression to `--jq`:
#        .[] | "<assoc>\u001f<body | gsub("[\u001e\u001f]"; "")>" + "\u001e"
#      BOTH halves are load-bearing: the strip because an UNSTRIPPED body can FORGE the
#      frame (the recorder's own comment at :2437 — `grep -n 'could FORGE the frame'` — names the measured exploit), the
#      `\u001e` because it is how records are split. NO OTHER VECTOR EXERCISES EITHER —
#      every other fixture feeds the frame PRE-BUILT through $STUB_COMMENTS, so the
#      recorder's expression is never evaluated and deleting the strip left the suite
#      GREEN. This one serves a JSON ENVELOPE (the shape real `gh api` returns) and
#      asserts through the POST COUNT.
#      ⛔ NON-VACUITY (measured): at head the strip removes the delimiters smuggled in the
#      body, the forged record never forms, and this run is UNAFFECTED by an unadmitted
#      author's comment ⇒ 1 POST. With `gsub(...)` deleted the smuggled
#      `\u001eOWNER\u001f<marker>` survives the split as its own record, the dedup matches
#      it, and the channel is suppressed for ever by a drive-by comment ⇒ 0 POST —
#      exactly the state the strip exists to prevent.
if [ -n "$DC_MARKER" ]; then
    _dcj_body="$(printf 'drive-by note\036OWNER\037%s' "$DC_MARKER")"
    _dcj_forged="$(jq -nc --arg b "$_dcj_body" '[{author_association:"NONE", body:$b}]')"
    STUB_COMMENT_JSON="$_dcj_forged" STUB_COMMENT_CAPTURE="$T/ccap_b4" \
        run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
    assert_eq "$(dc_posts "$DC_PR")" "1" \
        "14.1d(b4) a FORGED record smuggled inside a comment body does not satisfy the dedup (the delimiter strip is executed)"
    if [ -s "$T/ccap_b4" ] && command grep -qF -- "$DC_MARKER" "$T/ccap_b4"; then
        ok "14.1d(b4) …and the post it makes carries the real marker (the envelope reached the recorder, not a fixture)"
    else
        bad "14.1d(b4) the envelope vector did not post the marker — the ENVELOPE fixture never reached the caller's --jq"
    fi
else
    bad "14.1d(b4) vector SKIPPED — the marker fixture is empty; the frame-expression pin did NOT run"
fi
# (b3) ⛔ THE SUCCESS LINE'S SCOPE (#3168 review cycle 4). This line reports only what
#      the producing function observed — it created a comment — and it must NOT assert
#      the state of the BODY mirror, which FOUR of its five call sites reach unsaved.
#      The old tail "(body mirror retained: it is what re-triggers the gate)" was
#      deleted by this PR and nothing pinned its absence (measured: restoring it left
#      the suite at PASS=936 FAIL=0). The POSITIVE assertion comes first on purpose —
#      a negative alone passes on an EMPTY variable and would prove nothing.
assert_contains "$RECORD_OUT633" "as a COMMENT (#1224" \
    "14.1d the success line names the durable copy it created (stdout capture is live)"
assert_not_contains "$RECORD_OUT633" "body mirror retained" \
    "14.1d …and does not assert the BODY mirror's state, which this function cannot know"
assert_not_contains "$RECORD_OUT633" "re-triggers the gate" \
    "14.1d …nor re-assert the retired claim about what re-triggers the gate"
# (c) READ-FAILURE: `gh api` writes a NON-EMPTY error body to STDOUT and exits
#     non-zero. The durable post must be SKIPPED (never read as "no comment" ⇒
#     post), the warning must name it, and the record must still succeed.
STUB_COMMENTS_FAIL=1 STUB_COMMENT_CAPTURE="$T/ccap_c" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$(dc_posts "$DC_PR")" "0" "14.1d a FAILED comment read does not post (an error body is not 'no comment exists')"
assert_contains "$RECORD_ERR" "could not READ the PR comments" "14.1d …and the failure is reported loudly, not swallowed"
# ⛔ AND IT PROMISES NO RETRY IT CANNOT HONOUR (#3168 review cycle 4). "The verb that
#    produced this message has to be re-run to retry" is FALSE outright at ONE call site:
#    --recover-body refuses once a record exists. ⛔ THE FLUSH IS NOT THE SAME SHAPE and the
#    line must not flatten them (#3168 round-15): flush_pending_markers removes its pending
#    marker only when its body post SUCCEEDS, so a FAILED post IS retried by a second
#    --flush-pending — the message now states the conditional, not a flat denial.
assert_not_contains "$RECORD_ERR" "has to be re-run to retry" \
    "14.1d …and does not promise a verb-agnostic retry (false outright only at the recover-body site)"
assert_not_contains "$RECORD_ERR" "the body copy above is unaffected" \
    "14.1d …nor resurrect the old false claim that the body copy is unaffected"
assert_eq "$RECORD_RC" "0" "14.1d …and a failed comment read never fails the record [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
# (d) UNSIGNED-ONLY: the gate can never accept an unsigned marker, and a comment is
#     permanent, so it must never be published to that channel.
AI_REVIEW_GATE_KEY="" STUB_COMMENT_CAPTURE="$T/ccap_d" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$(dc_posts "$DC_PR")" "0" "14.1d an UNSIGNED marker is never published as a comment"
# (d-g) THE ADMISSION RULE IS PINNED **BEHAVIOURALLY** (#3168 re-review finding 3,
#       cycle 2). It is the ONLY author filter on a permanent public channel AND the
#       predicate the dedup matches against. A first version of this pin asserted the
#       rule's TEXT in the recorder's source, which is not the behaviour. The pin is a
#       pair that discriminates: the SAME marker, ALONE AS THE WHOLE BODY, from authors
#       on either side of the filter, must produce OPPOSITE POST counts. Per-association
#       runs, so dropping any ONE association from the filter reddens exactly that run
#       instead of hiding behind the others.
# ⛔ EVERY run below reuses $DC_PR, ON PURPOSE. The marker embeds `reviews/<pr>.json`,
#    so a fixture built from PR N's marker can never match a run on PR M — a first
#    draft used fresh PR numbers and posted 1 for every admitted vector (measured).
if [ -n "$DC_MARKER" ]; then
    for ADM_ASSOC in OWNER MEMBER COLLABORATOR; do
        STUB_COMMENTS="$ADM_ASSOC"$'\037'"$DC_MARKER"$'\036' \
            STUB_COMMENT_CAPTURE="$T/ccap_g_$ADM_ASSOC" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
        assert_eq "$(dc_posts "$DC_PR")" "0" \
            "14.1d(g) an ADMITTED $ADM_ASSOC comment already carrying the marker suppresses the duplicate"
    done
    STUB_COMMENTS="NONE"$'\037'"$DC_MARKER"$'\036'"FIRST_TIMER"$'\037'"$DC_MARKER"$'\036' \
        STUB_COMMENT_CAPTURE="$T/ccap_g_driveby" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
    assert_eq "$(dc_posts "$DC_PR")" "1" \
        "14.1d(g) …while an UNADMITTED author's comment carrying the SAME marker does NOT suppress it (drop-the-filter mutant: 0)"
    if [ -s "$T/ccap_g_driveby" ]; then
        ok "14.1d(g) …and the post it makes carries a body (the vector is not judging an empty capture)"
    else
        bad "14.1d(g) the drive-by vector captured no POST body — it would pass on a post that never happened"
    fi
else
    bad "14.1d(g) vector SKIPPED — the marker fixture is empty (14.1d's first vector captured nothing)"
fi
# (d-f) THE POST-FAILURE ARM (#3168 re-review finding 4). Nothing exercised it:
#       `STUB_COMMENT_POST_FAIL` was defined by the stub and exported by the harness
#       but NO vector ever set it, so swapping the failure line for the SUCCESS line
#       left the suite GREEN — a false-PASS-shaped mutant that tells an operator the
#       durable copy exists during exactly the 403 / spent-token window this arm
#       exists to report. Both halves are asserted: the failure is NAMED on stderr,
#       and the success line is NOT printed on stdout.
CPF_PR=424345
: > "$LOG"
STUB_COMMENT_POST_FAIL=1 STUB_COMMENT_CAPTURE="$T/ccap_f" run_record_633 "$CPF_PR" "$SHA" "$DC_CRUNS"
assert_contains "$RECORD_ERR" "could not post the #1224 review-evidence comment" \
    "14.1d(f) a FAILED comment POST is reported on stderr"
assert_not_contains "$RECORD_OUT633" "as a COMMENT (#1224" \
    "14.1d(f) …and the run does NOT claim a durable copy it failed to create (the false-PASS message)"
# (e) THE READ-FAILURE ARM'S EXIT CODE IS A TWO-VALUED ANSWER, and that IS the merge
#     resolution (ONE PRODUCER, main's semantics): the arm exits 0 ONLY when the durable
#     comment VERIFIABLY landed — a comment IS evidence the required check admits — and
#     exits 5 when the marker reached NEITHER channel. Both halves are driven here, so
#     "posted" and "swallowed" cannot collapse into one another again: collapsing them
#     is defect A reopened on the second channel.
STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' STUB_COMMENT_CAPTURE="$T/ccap_e" \
    run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$(dc_posts "$DC_PR")" "1" "14.1d a failed body read still ATTEMPTS the durable comment — the channel exists for exactly this failure"
assert_eq "$RECORD_RC" "0" "14.1d …and a comment that LANDED makes the run a success (a posted comment IS admitted evidence)"
STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' STUB_COMMENTS_FAIL=1 \
    STUB_COMMENT_CAPTURE="$T/ccap_e2" run_record_633 "$DC_PR" "$SHA" "$DC_CRUNS"
assert_eq "$RECORD_RC" "5" "14.1d …but a comment that did NOT land is still a NAMED failure (rc 5) — neither channel carries the marker [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_not_contains "$RECORD_ERR" "nothing carries the marker yet" "14.1d …and does not claim an ABSENCE it cannot know (a previous run's comment may carry it)"
# ⛔ CORRECTED (#3712 review round 5, P2): "CI CANNOT SEE IT" was an absence claim
#    this arm cannot make. Its only justification — "true on the only arm that emits
#    it" — was false: the body READ is exactly what failed here, so a PREVIOUS run's
#    body or comment may already carry the marker, and the gate reads both channels
#    independently. The pin had it PRESENT; it is now pinned ABSENT, with the
#    observable statement that replaced it pinned PRESENT.
assert_not_contains "$RECORD_ERR" "CI CANNOT SEE IT" \
    "14.1d …and does NOT claim CI cannot see the record — a previous run's copy may already carry it"
assert_contains "$RECORD_ERR" "is NOT observable from here" \
    "14.1d …it states what THIS run delivered and names what it cannot observe"
assert_not_contains "$RECORD_ERR" "currently INVISIBLE" \
    "14.1d …nor that the evidence is invisible"
assert_not_contains "$RECORD_ERR" "attempted on the line above" \
    "14.1d …nor claim a comment post it cannot know happened (the unsigned and read-failure arms post none)"
assert_not_contains "$RECORD_ERR" "already admits the evidence" \
    "14.1d …nor derive ADMISSION from a POST 2xx (author_association decides admission, see residual 1)"
# 14.1d(h) ⛔ THE EXIT-5 NOUN (#3168 re-review, latest comment, P2). Both exit-5
#      messages said "the signed marker" — but BOTH arms are reachable with
#      `MARKER_SIGNED=0` (:6537-6549: no gate key warns and CONTINUES), so the
#      adjective named a property those bytes need not have. These
#      two vectors drive that exact conjunction (key unset + a refused body GET / a
#      refused body PATCH) and are placed HERE, inside §14, because a fresh CLEAN
#      mint needs a verifiable --evidence artifact: at the end of the file §20 has
#      left `EV_REF` on a NOT-CLEAN comment, so the mint is refused at rc 3 and never
#      reaches the body channel at all — green for the wrong reason (measured on the
#      first draft of these vectors).
#      The positive assertion comes FIRST in each pair so the negative cannot pass on
#      an empty capture. RED pre-fix: "so the signed marker was NOT written into the
#      PR body" / "the signed marker for … could NOT be PATCHed".
UNC_PR=424360
AI_REVIEW_GATE_KEY="" STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' \
    run_record_633 "$UNC_PR" "$SHA" '[]'
assert_eq "$RECORD_RC" "5" \
    "14.1d(h) an UNKEYED run whose body READ fails is still a NAMED failure (rc 5) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_contains "$RECORD_ERR" "body-marker-unposted" \
    "14.1d(h) …its exit-5 message still carries the NAMED state (capture is live)"
assert_contains "$RECORD_ERR" "UNSIGNED" \
    "14.1d(h) …and blames UNSIGNEDNESS, not the API — the comment channel was never attempted, BY POLICY"
assert_not_contains "$RECORD_ERR" "the signed marker was NOT written" \
    "14.1d(h) …and does NOT call these bytes 'the signed marker' — this arm is reached with MARKER_SIGNED=0"
UNC_PR2=424361
AI_REVIEW_GATE_KEY="" STUB_PATCH_FAIL=1 STUB_BODY="PR body — no review evidence yet" \
    run_record_633 "$UNC_PR2" "$SHA" '[]'
assert_eq "$RECORD_RC" "5" \
    "14.1d(h) an UNKEYED run whose body PATCH fails is still a NAMED failure (rc 5) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_contains "$RECORD_ERR" "the marker for daniel-ospina/agent-infra#$UNC_PR2 could NOT be PATCHed" \
    "14.1d(h) …its exit-5 message still names the marker (capture is live)"
assert_not_contains "$RECORD_ERR" "the signed marker for daniel-ospina/agent-infra#$UNC_PR2 could NOT be PATCHed" \
    "14.1d(h) …and does NOT call it 'the signed marker' on the PATCH-failure arm either"

# 14.1d(i) ⛔ THE PERSIST RESULT DECIDES THE REMEDY (#3168 review P2). The exit-0
#      message used to assert the marker "is also kept in <pending file>" — and to
#      offer `--flush-pending` as the remedy — even when the persist ABOVE it had just
#      failed and warned that that remedy "WILL FIND NOTHING". Two sentences in one
#      arm cannot both be true, and the one an operator ACTS on is the remedy.
#      Reaching the persist-failure sub-path needs the pending DIRECTORY to be
#      un-makeable: a regular FILE is put where the directory belongs, so the
#      `mkdir -p` inside `marker_pending_write` fails. BOTH body-read arms are
#      driven here (comment landed ⇒ exit 0; comment failed too ⇒ exit 5), because
#      both used to print the same unconditional claim.
#      RED pre-fix: every `assert_not_contains` below, on a capture the
#      `assert_contains` beside it proves is live.
PEND_CONF_DIR="$F_HOME/.pi/agent/reviews"
mkdir -p "$PEND_CONF_DIR"
rm -rf "$PEND_CONF_DIR/pending"     # earlier vectors left a real DIRECTORY here
: > "$PEND_CONF_DIR/pending"        # a FILE where the pending DIR must be
PERSIST_PR=424362
STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' \
    run_record_633 "$PERSIST_PR" "$SHA" "$DC_CRUNS"
assert_eq "$RECORD_RC" "0" \
    "14.1d(i) a persist-FAILED body-read run whose comment landed is still a success (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_contains "$RECORD_ERR" "could NOT persist the pending marker" \
    "14.1d(i) …the failed persist is reported (positive-first: the capture is live)"
assert_not_contains "$RECORD_ERR" "The marker is also kept in" \
    "14.1d(i) …and the exit-0 message does NOT claim the marker is on disk — the 'NOT ON DISK' branch fires instead"
assert_contains "$RECORD_ERR" "THIS RUN PLACED NO BODY COPY ON ANY CHANNEL" \
    "14.1d(i) …naming the real, ATTEMPT-scoped state (this run's write did not land) instead of claiming the file is empty or that a flush would find nothing — both of which the deterministic marker falsifies"
assert_not_contains "$RECORD_ERR" "THIS RUN'S BODY COPY IS ON NO CHANNEL" \
    "14.1d(i) …and the round-3 SPELLING is gone: 'BODY COPY IS ON NO CHANNEL' read as a claim about the body's CONTENTS, which this arm cannot observe, where 'PLACED NO BODY COPY' states only what THIS RUN did"
# ⛔ THE ROUND-9 INVARIANT ON THE EXIT-0 CAPTURE TOO (#3712 review round 10, P2).
# The two negatives below already existed, but both read the rc-5 capture ($PERSIST_PR2);
# the rc-0 arm's own line carried round 3's falsified denial until round 10 ("would find NOTHING for the
# marker this run owed … neither delivers these bytes") and stayed GREEN under a live
# instance of the forbidden literal — the guard was never pointed at this stream. The
# capture is the same one proved live by the two `assert_contains` above, so these cost
# nothing and close the gap. RED pre-fix: both literals are in the exit-0 message.
assert_not_contains "$RECORD_ERR" "would find NOTHING" \
    "14.1d(i) …and the exit-0 remedy never PREDICTS the flush's output either — the marker is deterministic, so an earlier run at this head may hold exactly these bytes"
assert_not_contains "$RECORD_ERR" "neither delivers these bytes" \
    "14.1d(i) …nor denies the flush can deliver them, which would withdraw the working one-command remedy (round 10: it must be OFFERED in both arms)"
# ⛔ THE EXIT-0 REMEDY ITSELF MUST BE PINNED, NOT ONLY ITS DENIALS (#3712 review at
# `1dece6108`, FINDING 1 — the absent-mutation-leg class of agent-infra#3442).
# Every row above on this capture is either a POSITIVE about a state that is still
# true without the remedy (`:5526` — `rg -n '^assert_contains .*THIS RUN PLACED NO BODY COPY'`) or a
# NEGATIVE about a denial; deleting the remedy clause makes each negative MORE satisfied, so the
# whole block stayed GREEN with the round-10 regression direction live. The label at `:5540`
# (`rg -n '^    "14\.1d\(i\) …nor denies'`) states the invariant and the comment above it
# repeats it, but nothing enforced it on THIS arm — the only two positives on the offer read the
# rc-5 capture (`:5589`/`:5591` — `rg -n 'assert_contains "\$RECORD_ERR" "(TRY --flush-pending|findings/note, the diff)'`
# gives FOUR rows, the LAST TWO of which are this rc-5 capture's). These two are DIFFERENT
# predicates from those two rows on a DIFFERENT capture, so neither can redden in lockstep with
# them: `:5589`/`:5591` prove the exit-5 arm offers the flush, these prove the exit-0 arm still does.
# RED pre-fix: delete the `So TRY --flush-pending $PR ${REPO:-} …` clause from the
# exit-0 else-branch of `scripts/record-review.sh` and BOTH rows below red. MEASURED in
# this lane, both directions, full suite each time:
#   · mutant alone                  → PASS=1453 FAIL=0   (the finding: the clause is unpinned)
#   · mutant + these two rows       → PASS=1453 FAIL=2   (both new rows, each naming its literal)
#   · head (no mutant) + these rows → PASS=1455 FAIL=0
# i.e. the rows are the only thing standing between that deletion and a green suite, and
# the untouched head stays green — a pin, not a regression.
assert_contains "$RECORD_ERR" "TRY --flush-pending" \
    "14.1d(i) …and the exit-0 arm still OFFERS the flush — the sibling rows here only FORBID the denial and the output prediction, so without this row the working one-command remedy can be deleted from this arm and every row stays GREEN (#3712 review at 1dece6108, FINDING 1)"
assert_contains "$RECORD_ERR" "findings/note, the diff and a signature" \
    "14.1d(i) …and the identity test it hands the operator on THIS arm enumerates the same inputs as its exit-5 sibling, findings=/note= included — round 10 added the clause to BOTH sites and only the exit-5 one was pinned (#3712 review at 1dece6108, FINDING 1)"
PERSIST_PR2=424363
STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' STUB_COMMENTS_FAIL=1 \
    run_record_633 "$PERSIST_PR2" "$SHA" "$DC_CRUNS"
assert_eq "$RECORD_RC" "5" \
    "14.1d(i) …and with the comment failing too the arm is still a NAMED failure (rc 5) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_not_contains "$RECORD_ERR" "The marker is kept in" \
    "14.1d(i) …whose exit-5 message never ASSERTS the marker IS kept in the pending file (it cannot know: it never read it)"
assert_contains "$RECORD_ERR" "THIS RUN WROTE NO PENDING COPY" \
    "14.1d(i) …but states the observed fact instead — THIS run's write failed — which is not 'the record is missing' (the line above says the record IS saved) and not 'the file is empty'"
# ⛔ THE FLUSH CLAIM IS SCOPED TO THIS RUN'S MARKER, AND ITS OUTCOME IS NEVER PREDICTED
# (#3712 round 3; REWRITTEN in round 9 after a fresh review falsified the round-3 form).
# Round 3 reasoned: the pending file is keyed by (repo, PR) and OVERWRITTEN, so an earlier
# run's marker is still there, therefore "would find NOTHING" is wrong — and replaced it with
# "it can only deliver an OLDER marker … and neither delivers these bytes". That is ALSO
# false, and the reason is the determinism of the marker itself: it is built from
# (PR, verdict, head, diff, repo, key) with no timestamp and no run id, so an EARLIER RUN AT
# THE SAME HEAD leaves BYTE-IDENTICAL bytes — `--flush-pending` would deliver exactly what
# this run owed. The process also never READS the file, so it cannot report its contents in
# either direction. Hence the rule now enforced below: state only what was observed (THIS
# run's write failed), never predict the flush's OUTPUT, and OFFER the flush in both arms
# rather than denying it — an incorrect denial costs an operator the working one-command
# remedy that this whole arm exists to point at.
assert_contains "$RECORD_ERR" "is NOT thereby this run's evidence" \
    "14.1d(i) …and the exit-5 remedy scopes a flushed line to the marker's ANATOMY, not to this run — a delivered line naming the sha alone is not evidence, so the operator must read the WHOLE line. A DIFFERENT predicate from the row above on purpose: two assert_contains rows sharing one literal AND one capture can only ever redden in lockstep, so the second would add no discriminating power (#3712 review, finding 2)"
assert_contains "$RECORD_ERR" "TRY --flush-pending" \
    "14.1d(i) …and still OFFERS the flush: an earlier run at the same head leaves byte-identical bytes, so denying it withdraws a remedy that works (round 9)"
assert_contains "$RECORD_ERR" "findings/note, the diff and a signature" \
    "14.1d(i) …and the identity test it hands the operator enumerates the SAME inputs as its exit-0 sibling, findings=/note= included — a not-clean marker splices both in, so a test naming only verdict+diff+sig admits a DIFFERENT run's open-findings record (#3712 review round 4)"
assert_not_contains "$RECORD_ERR" "would find NOTHING" \
    "14.1d(i) …while never PREDICTING the flush's output, which depends on a file this run never read"
assert_not_contains "$RECORD_ERR" "neither delivers these bytes" \
    "14.1d(i) …and never asserting the flush cannot deliver these bytes — the marker is deterministic, so an earlier run at this head holds exactly them (round 9 falsified this)"
# ⛔ THE EXIT-5 WHY-CLAUSE MAY NAME NO CAUSE THIS ARM CANNOT OBSERVE (#3712 review at
# `0aca7410b`, finding F2 — the MISSING MUTATION LEG). `post_review_evidence_comment`
# returns 1 for TWO different events: the comment READ failed (the post is then SKIPPED
# by design — never attempted) and the POST itself was refused. This arm discards the
# error text, so it cannot tell them apart and may name NEITHER. Main's wording did name
# the POST — "the #1224 evidence COMMENT could not be posted either" — and that is the
# misdirection the round-5 fix removes: a lane reading it goes hunting API permissions
# instead of configuring the gate key. Until now NOTHING pinned it: restoring main's
# sentence at the why-clause left EVERY row of this capture GREEN (measured in the PR
# body), which is the absent-mutation-leg class of agent-infra#3442 — the fix was
# invisible to the suite. These rows read the SAME already-live rc-5 capture as the rows
# above (signed key ⇒ this arm is reached; persist failed ⇒ this branch is the one it
# prints), so the coverage costs three rows and no new vector.
# The two POSITIVE rows come first ON PURPOSE: the negative below cannot pass on a
# capture that never reached the arm — it would also pass on an EMPTY string.
assert_contains "$RECORD_ERR" "NO durable comment copy of its own" \
    "14.1d(i) …and the exit-5 why-clause reports what THIS RUN published, not what the API did (#3712 F2)"
assert_contains "$RECORD_ERR" "SKIPPED by design" \
    "14.1d(i) …naming the never-ATTEMPTED branch as well as the refused one, because this arm cannot distinguish them and so may not pick one (#3712 F2)"
assert_not_contains "$RECORD_ERR" "COMMENT could not be posted" \
    "14.1d(i) …and never claims the comment POST was refused — that is unobservable here (RED when main's sentence is restored; #3712 F2)"
# ⛔ THE SAME CLASS, ONE CALL FURTHER IN (#3712 review round 2, P3):
# `post_review_evidence_comment` runs INSIDE this arm and, when its comment READ
# fails too, used to print "The signed record AND THE BODY MARKER are unaffected" —
# on the very stream whose other two lines say the marker is on no channel and not on
# disk. A caller cannot know the marker survived; that sentence asserted it anyway.
assert_not_contains "$RECORD_ERR" "and the body marker are unaffected" \
    "14.1d(i) …and NO line in the capture claims the body marker survived a failed persist"
assert_contains "$RECORD_ERR" "This line makes NO CLAIM about the body marker" \
    "14.1d(i) …the comment-read failure instead defers to the persist line that decides it"
# ⛔ THE SAME CLASS AT THE COMMENT-**POST** SITE (#3712 review round 4, P2):
# the read arm's sibling note ("could not post the #1224 review-evidence comment")
# asserted "the signed record AND THE BODY MARKER are still saved". With the persist
# already failed that is false — the marker is on no channel — so it now defers too.
# It is a SEPARATE site from the READ failure above, and no vector drove it with a
# failed persist, so the invariant the two assertions above describe was stated more
# broadly than it was enforced. This vector closes that gap.
PERSIST_PR3=424364
STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' STUB_COMMENT_POST_FAIL=1 \
    run_record_633 "$PERSIST_PR3" "$SHA" "$DC_CRUNS"
assert_not_contains "$RECORD_ERR" "the body marker are still saved" \
    "14.1d(i) …nor does the comment-POST note claim the body marker survived a failed persist"
assert_contains "$RECORD_ERR" "this note makes NO CLAIM about the body marker" \
    "14.1d(i) …it defers to the persist line instead, so no line in this capture asserts the marker is saved"
# ⛔ THE PATCH ARM'S OWN REMEDY MUST BRANCH ON *ITS* PERSIST RESULT (#3712 review
# round 5, P3). `--flush-pending` can only fire the `edited` event if a PENDING FILE
# exists; when the post-PATCH persist failed it answers "nothing pending … Nothing was
# written" and exits 0 without touching the body. The read arm branches its remedy on
# the persist result — this arm offered the inert flush anyway. No vector combined a
# failed PATCH with an unwritable pending dir, so it went unpinned; this one does.
PATCH_FAIL_PR=424365
STUB_PATCH_FAIL=1 STUB_BODY="PR body — no review evidence yet" \
    run_record_633 "$PATCH_FAIL_PR" "$SHA" "$DC_CRUNS"
assert_contains "$RECORD_ERR" "THIS RUN WROTE NO PENDING COPY" \
    "14.1d(j) the PATCH arm's comment-visible message says what was observed — neither of its persist attempts wrote — and not what the file holds"
assert_not_contains "$RECORD_ERR" "or post the body copy with --flush-pending, to fire" \
    "14.1d(j) …and does NOT offer the inert flush as the route to the edited event"
# ⛔ A ⚠️ LINE'S *ABSENCE* IS DISPOSITIVE, ITS APPEARANCE IS NOT (#3712 review round 10,
# P3). The PATCH arm's pending-file paragraph said neither the appearance nor the absence
# of a `⚠️ body-marker:` line tells you the file's contents. The ABSENCE does: the
# both-attempts-failed warning prints only when PATCH_PERSISTED=0, so NO line at all means
# the pre-PATCH write landed and the file holds exactly the bytes this run minted. Only the
# APPEARANCE is non-dispositive (the retry can succeed after a failed early write) — which
# is the half the paragraph already had right. The paragraph is reachable ONLY when the
# PATCH and the durable comment BOTH fail, which is the vector below, with the pending
# path still un-makeable (a FILE where the directory belongs). RED pre-fix: the negative
# (the false universal) AND the positive (that silence is dispositive).
PATCH_CMT_FAIL_PR=424367
STUB_PATCH_FAIL=1 STUB_BODY="PR body — no review evidence yet" STUB_COMMENTS_FAIL=1 \
    run_record_633 "$PATCH_CMT_FAIL_PR" "$SHA" "$DC_CRUNS"
assert_eq "$RECORD_RC" "5" \
    "14.1d(j3) a refused PATCH with a refused durable comment is still a NAMED failure (rc 5) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_contains "$RECORD_ERR" "Only NEITHER line appearing is dispositive" \
    "14.1d(j3) …and its pending-file paragraph says the ABSENCE of a persist warning IS dispositive — the PRE-PATCH write landed and the bytes are on disk (capture live)"
assert_not_contains "$RECORD_ERR" "tells you the file's contents" \
    "14.1d(j3) …instead of telling an operator whose PRE-PATCH write landed that the file's contents cannot be known"
rm -f "$PEND_CONF_DIR/pending"
mkdir -p "$PEND_CONF_DIR/pending"   # restore the real directory for later vectors

# ⛔ 14.1d(j2) A FAILED *RETRY* DOES NOT MAKE THE BYTES ABSENT (#3712 review round 6, P2).
# The arm writes the pending file TWICE: once BEFORE the PATCH (so a shell killed mid-PATCH
# leaves a recoverable copy) and again as a RETRY when the PATCH is refused. Both write the
# same $MISSING to the same (repo,PR)-keyed path, and `marker_pending_write` returns 1 WITHOUT
# unlinking the target — so when the retry fails after the first write succeeded, this run's
# bytes ARE on disk and `--flush-pending` WOULD deliver them. Reading the state off the retry
# alone told an operator the opposite …and withdrew a remedy that worked. This vector drives
# exactly that window with a counting `mv` stub: the FIRST pending-marker move succeeds, the
# SECOND fails. ⛔ The stub keys on the DESTINATION — the 3rd argument of `mv -f`, which is the
# shape `marker_pending_write` uses — because keying on the 2nd would test the `.tmp` SOURCE,
# which never ends in `.marker` and so never fires (measured: an earlier draft of this stub
# matched nothing and the vector passed VACUOUSLY with counter 0). It is scoped to
# `*/pending/*.marker`, so the recorder's other `mv` (:3501, `command mv "$tmp" "$out"` — OUT of the mktemp) is unaffected.
rm -f "$T/bin/mv"
_MV_REAL="$(command -v mv)"
_MV_COUNT="$T/mvcount-pending"
printf '0' > "$_MV_COUNT"
cat > "$T/bin/mv" <<MVSTUB
#!/usr/bin/env bash
# marker_pending_write runs "command mv -f <src> <dst>", so the DESTINATION is the 3rd
# argument. Matching the 2nd would test the .tmp SOURCE, which never ends in .marker.
case "\${3:-}" in
  */pending/*.marker)
    n=\$(cat "$_MV_COUNT" 2>/dev/null || echo 0); n=\$((n+1)); printf '%s' "\$n" > "$_MV_COUNT"
    if [ "\$n" -ge 2 ]; then exit 1; fi ;;
esac
exec "$_MV_REAL" "\$@"
MVSTUB
chmod +x "$T/bin/mv"
PEND_RETRY_PR=424366
STUB_PATCH_FAIL=1 STUB_BODY="PR body — no review evidence yet" \
    run_record_633 "$PEND_RETRY_PR" "$SHA" "$DC_CRUNS"
rm -f "$T/bin/mv"
assert_eq "$(cat "$_MV_COUNT" 2>/dev/null || echo 0)" "2" \
    "14.1d(j2) NON-VACUITY: the pending-marker move ran twice and the SECOND one failed (the window below is REACHED, not assumed)"
assert_not_contains "$RECORD_ERR" "THIS RUN WROTE NO PENDING COPY" \
    "14.1d(j2) …a failed RETRY makes NO 'this run wrote nothing' claim — the pre-PATCH copy is still on disk"
assert_contains "$RECORD_ERR" "or post the body copy with --flush-pending, to fire" \
    "14.1d(j2) …so the WORKING flush remedy is still offered, instead of the hand-PATCH a false absence claim demands"
assert_not_contains "$RECORD_ERR" "⚠️ body-marker: could" \
    "14.1d(j2) …and NO persist warning is printed in EITHER spelling ('could not' is the pre-PATCH line, 'could NOT' the both-failed one; the literal is deliberately case-truncated so a regression printing the pre-PATCH warning reddens too): the bytes ARE on disk, so there is nothing to warn about"

# 14.1e THE DURABLE CHANNEL IN `--recover-body` (#3168 fresh-review finding 1).
#      The recovery verb exists BECAUSE the body was the only copy of the verdict that
#      travelled — until #1224, when this recorder began posting a durable comment copy too.
#      Handing the recovered marker back into that same MUTABLE field, with the comment
#      channel as the only durable twin, would still leave a later body edit able to erase the
#      copy of what the run had just restored. This vector reddens when the call is
#      removed, and it reddens through BOTH of its durable-channel assertions —
#      the `assert_eq` label `14.1e …and publishes the recovered marker to the durable
#      comment channel` (got: 0, want: 1) and the `bad` label `14.1e the durable comment
#      did not carry the recovered marker line` — which is the same discriminator shape
#      as 14.1d(e). ⛔ The counts are named as ASSERTIONS, not quoted as `PASS=n FAIL=m`
#      (#3168 review P3): the numbers that used to sit here had already rotted, and
#      §20.11 of this file states the same rule for its own count.
DC_RB_PR=424951
rb_clear
RB_M_E="$(rb_marker "$DC_RB_PR" "review recorded: reviews/${DC_RB_PR}.json verdict=clean @ $RB_HEAD diff=$RB_DIFF ($RB_REPO)")" \
  || bad "fixture: rb_marker could not be BUILT — the 14.1e arm would otherwise fail on a MISSING marker"
STUB_COMMENT_BODIES=""
STUB_COMMENT_CAPTURE="$T/ccap_14e"
STUB_BODY="PR body carrying a recovered verdict.

$RB_M_E"
export STUB_BODY STUB_COMMENT_BODIES STUB_COMMENT_CAPTURE
: >"$LOG"
run_recover "$DC_RB_PR" "$RB_REPO"
assert_eq "$RB_RC" "0" "14.1e --recover-body still restores the record (exit 0)"
assert_eq "$(dc_posts "$DC_RB_PR")" "1" "14.1e …and publishes the recovered marker to the durable comment channel"
DC_RB_BODY="$(jq -r '.body // empty' "$T/ccap_14e" 2>/dev/null || true)"
if [ -n "$DC_RB_BODY" ] && grep -qxF -- "$RB_M_E" <<<"$DC_RB_BODY"; then
    ok "14.1e …carrying the RECOVERED marker line verbatim, alone on its line (gate-admissible)"
else
    bad "14.1e the durable comment did not carry the recovered marker line (capture: $DC_RB_BODY)"
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
# ⛔ THE PROPERTY IS "NO REMEDIATION", NOT "NO check-runs CALL" (#3440). The remediation is
# a FILTERED read of the gate's own runs (`-f check_name=…`, raw envelope) plus a job
# RE-RUN; a deliberate stale sha must never reach either, or the rerun lands in the PR's
# per-PR concurrency group and cancels the REAL head's in-flight gate run. The record now
# makes ONE read of its own — the #3440 surface observation, unfiltered and with `--jq` —
# and that read is not the remediation. The count is pinned to exactly one so the
# distinction cannot quietly rot into "the remediation stopped reading".
if grep -qF -- "actions/jobs/" "$LOG" || grep -qF -- "check_name=" "$LOG"; then
    bad "14.7 force-stale runs NO stale-run remediation — a filtered gate query or a rerun is the remediation (log: $(cat "$LOG"))"
elif [ "$(grep -cF -- "/check-runs" "$LOG")" != "1" ]; then
    bad "14.7 force-stale should make exactly ONE check-runs read (the #3440 surface observation), saw $(grep -cF -- "/check-runs" "$LOG") (log: $(cat "$LOG"))"
else
    ok "14.7 force-stale runs no stale-run remediation (no filtered gate query, no rerun) and only the one surface read"
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

# 14.10 A body PATCH failure is a NAMED non-zero state (defect A, #10522), never
#      "record still saved" + exit 0: the record is invisible to CI in that state,
#      so reporting success is how a correctly reviewed PR (tortoise#10677) sat
#      blocked by a bookkeeping failure. The marker is kept so delivery is
#      retryable WITHOUT re-recording.
STUB_BODY="PR body — no review evidence yet" STUB_PATCH_FAIL=1 run_record_633 424329 "$SHA" \
    '[{"name":"ai-review-gate","status":"completed","conclusion":"failure","id":500}]'
[ "$RECORD_RC" = "5" ] && ok "14.10 PATCH failure is a NAMED non-zero exit (rc 5)" || bad "14.10 PATCH failure exit (rc=$RECORD_RC, want 5; err=$RECORD_ERR)"
[ -f "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424329.json" ] && ok "14.10 record written despite PATCH failure" || bad "14.10 record written despite PATCH failure"
assert_contains "$RECORD_ERR" "body-marker-unposted" "14.10 the failure has a NAMED state (body-marker-unposted)"
PEND14="$F_HOME/.pi/agent/reviews/pending/daniel-ospina__agent-infra-424329.marker"
[ -f "$PEND14" ] && ok "14.10 the signed marker is KEPT for retry (durable pending file)" || bad "14.10 no durable pending marker — the evidence would be lost"
if grep -qF 'review recorded:' "$PEND14" 2>/dev/null; then ok "14.10 …and it holds the marker line verbatim"; else bad "14.10 the pending file does not hold the marker line"; fi
# 14.10a2 THE DURABLE CHANNEL IN THE PATCH-FAILURE ARM (fresh-review finding 2;
#       the ONE arm #2983's single producer left out — agent-infra#3363).
#       The channel's producer is called just BEFORE this arm's `exit 5`, and nothing
#       asserted it: deleting the call left BOTH suites green (measured: PASS=921
#       FAIL=0 and 190/190). This is the arm with the MEASURED real-world trigger
#       (the 403/spent-token window behind tortoise#10677) — and the two channels
#       need different scopes (`pull-requests:write` for the body, `issues:write`
#       for the comment), so this is exactly the run where the body fails and the
#       comment could still have delivered. A revert of that one line re-opens
#       "exits 5 having published nothing to the channel it exists for".
assert_eq "$(dc_posts 424329)" "1" \
    "14.10a2 the PATCH-failure arm still publishes the durable comment (the arm the channel exists for)"
# 14.10a3 THE EXIT-5 MESSAGE'S SCOPE (#3168 review cycle 3). Three review cycles in a
#        row found these operator messages asserting more than the emitting code can
#        know — "CI CANNOT SEE IT", "a durable comment was attempted on the line above",
#        "ai-review-gate already admits the evidence". Every one of those was FALSE at a
#        reachable arm, and NOTHING pinned the text, so any of them could come back with
#        a green suite. These assertions are the pin: the message scopes itself to the
#        BODY channel and does not resurrect the discredited claims.
#        ⛔ THE NEGATIVES FOR THE *READ* ARM LIVE IN 14.1d (#3168 review cycle 4):
#        "CI CANNOT SEE IT" shipped on main in the BODY-READ-failure message, so
#        asserting it here — against the PATCH arm's stderr — guarded an arm the
#        phrase never occupied. It is kept below as defence in depth for the PATCH
#        message, but 14.1d is where it is load-bearing.
assert_contains "$RECORD_ERR" "body-marker-unposted" "14.10a3 the exit-5 failure still has its NAMED state"
assert_contains "$RECORD_ERR" "COVERS THE PR BODY ONLY" "14.10a3 …and scopes itself to the body channel (the only thing it can assert)"
assert_not_contains "$RECORD_ERR" "CI CANNOT SEE IT" "14.10a3 …it must NOT assert that CI cannot see the evidence (a posted comment IS admitted by the gate)"
assert_not_contains "$RECORD_ERR" "currently INVISIBLE" "14.10a3 …nor that the evidence is invisible"
assert_not_contains "$RECORD_ERR" "attempted on the line above" "14.10a3 …nor claim a comment post it cannot know happened (the unsigned and read-failure arms post none)"
assert_not_contains "$RECORD_ERR" "already admits the evidence" "14.10a3 …nor derive ADMISSION from a POST 2xx (author_association decides admission, see residual 1)"
if grep -qF -- "actions/jobs/" "$LOG"; then
    bad "14.10 no rerun without a posted marker (log: $(cat "$LOG"))"
else
    ok "14.10 no rerun without a posted marker"
fi
# 14.10b …and `--flush-pending` DELIVERS it later without a second review and
#       without touching the record (a re-record would dilute the evidence).
REC_BEFORE_14B="$(cat "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424329.json" 2>/dev/null || true)"
FL_RC=0
FL_CAP="$T/flushcap"
: > "$FL_CAP"; : > "$LOG"
FL_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" STUB_CAPTURE="$FL_CAP" \
    STUB_BODY="PR body — no review evidence yet" \
    bash "$RECORD" --flush-pending 424329 daniel-ospina/agent-infra 2>&1)" || FL_RC=$?
# ⛔ DELIVERY, NOT DELETION (fresh-review P2): `rm -f` + exit 0 satisfied every
# other assertion here, and the empty-pending-file mutant did exactly that.
if grep -qF -- "-X PATCH" "$LOG"; then ok "14.10b the flush actually PATCHed the body (transport, not just an exit code)"; else bad "14.10b the flush exited 0 without a PATCH — deletion is not delivery (log: $(cat "$LOG"))"; fi
# 14.10b2 THE DURABLE CHANNEL IN THE FLUSH (fresh-review finding 2).
#       `flush_pending_markers` calls the durable channel's single producer BEFORE
#       `post_marker`, so a body-side failure cannot short-circuit the durable copy —
#       and deleting that call left both suites green. The flush is the run that
#       DELIVERS a marker whose body channel already failed once, so it is the second
#       place the durable copy must appear, not an optimization. Asserted by DELTA on
#       the shared log, which `run_record_633`/this arm truncate first, so the count is
#       this run's alone. ⛔ NO `MARKER_SIGNED` on this path — that global is set only in
#       the MINT — so this vector also pins the producer's local `sig=` re-verify.
assert_eq "$(dc_posts 424329)" "1" \
    "14.10b2 --flush-pending also publishes the durable comment (not just the body PATCH)"
# 14.10b3 THE FLUSH ORDERING IS LOAD-BEARING, SO PIN IT (#3168 re-review finding 5).
#       The code says the durable call is "Placed before post_marker() so a body-side
#       failure cannot short-circuit it", but 14.10b2 above only exercises a
#       SUCCESSFUL PATCH — so MOVING the call inside that branch left the suite at
#       PASS=1005 FAIL=0 (measured with the ordering inverted). The flush exists for
#       the run whose BODY channel already failed once, so the discriminating case is
#       a flush whose PATCH fails AGAIN: the durable copy must still be attempted.
#       That is the whole reason the call sits above the `if post_marker`.
FL2_PR=424344
STUB_BODY_FAIL=1 STUB_BODY_FAIL_TEXT='gh: Not Found (HTTP 404)' run_record_633 "$FL2_PR" "$SHA" '[]'
PEND14B="$F_HOME/.pi/agent/reviews/pending/daniel-ospina__agent-infra-$FL2_PR.marker"
if [ -f "$PEND14B" ]; then ok "14.10b3 fixture: the failed body read left a pending marker to flush"; else bad "14.10b3 fixture missing — nothing pending, so the vector would judge nothing"; fi
: > "$LOG"
FL2_RC=0
FL2_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" STUB_PATCH_FAIL=1 \
    STUB_BODY="PR body — no review evidence yet" \
    bash "$RECORD" --flush-pending "$FL2_PR" daniel-ospina/agent-infra 2>&1)" || FL2_RC=$?
assert_eq "$(dc_posts "$FL2_PR")" "1" \
    "14.10b3 the flush publishes the durable comment even when its body PATCH FAILS (ordering, not luck)"
assert_contains "$FL2_OUT" "as a COMMENT (#1224" \
    "14.10b3 …and says so, so the operator can tell the two channels apart [out: $(printf '%s' "$FL2_OUT" | tr '\n' ' ')]"
# 14.10b4 NO SIGNEDNESS CLAIM ON THE FLUSH SUCCESS LINE (#3168 re-review P3). The
#        marker is signed BEFORE it is persisted, so a KEYED run's pending file does
#        carry a `sig=` — but both body-channel arms are reachable with MARKER_SIGNED=0
#        (no gate key, or openssl producing nothing: a warning then CONTINUES), so an
#        unsigned marker is exactly what a flush can be holding. This line said "the
#        pending signed marker", the same false noun the two exit-5 arms were corrected
#        for. Same class, third site, and it was the one the PR's own prose quotes.
#        Driven through the CLI on an UNSIGNED pending marker (produced by a key-less
#        run whose body PATCH failed, i.e. the production shape), and asserted as a PAIR:
#        the honest noun is present, the false one is absent — so a revert reddens the
#        negative instead of passing on an empty capture.
FL3_PR=424351
AI_REVIEW_GATE_KEY="" STUB_PATCH_FAIL=1 run_record_633 "$FL3_PR" "$SHA" '[]'
PEND14C="$F_HOME/.pi/agent/reviews/pending/daniel-ospina__agent-infra-$FL3_PR.marker"
if [ -f "$PEND14C" ]; then
    if grep -qF -- " sig=" "$PEND14C"; then
        bad "14.10b4 fixture is SIGNED — this vector would not test the noun (pending file carries a sig=)"
    else
        ok "14.10b4 fixture: a key-less body-PATCH failure left an UNSIGNED pending marker"
    fi
    : > "$LOG"; FL3_RC=0
    FL3_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" \
        STUB_BODY="PR body — no review evidence yet" \
        bash "$RECORD" --flush-pending "$FL3_PR" daniel-ospina/agent-infra 2>&1)" || FL3_RC=$?
    assert_contains "$FL3_OUT" "delivered the pending marker" \
        "14.10b4 the flush success line names the pending marker it delivered [out: $(printf '%s' "$FL3_OUT" | tr '\n' ' ')]"
    assert_not_contains "$FL3_OUT" "pending signed marker" \
        "14.10b4 …and does NOT call an unsigned marker 'signed' (the noun the exit-5 arms were corrected for)"
    assert_eq "$FL3_RC" "0" "14.10b4 …and the flush still succeeds (the wording change is not a behaviour change)"
else
    bad "14.10b4 vector SKIPPED — no pending marker was written; the noun pin did NOT run"
fi
assert_contains "$(cat "$FL_CAP" 2>/dev/null)" "review recorded: reviews/424329.json" "14.10b the delivered body carries the marker line"
# 14.10q A BODY THAT ONLY *QUOTES* THE MARKER IS NOT DELIVERY (review round 2
#       finding 3). `post_marker` tested the marker with `grep -qF` — a SUBSTRING
#       test — while the gate anchors `^…$`. Measured before the fix: a body that
#       merely quoted the marker made `--flush-pending` return 0, print "delivered",
#       and DELETE the pending file — defect A on the retry channel, destroying the
#       only surviving copy of a marker that was never delivered. The vector needs
#       BOTH halves: a PATCH must happen, and the delivered body must carry the
#       marker as its OWN line.
Q14C_MARKER='review recorded: reviews/424329.json verdict=clean @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (daniel-ospina/agent-infra)'
mkdir -p "$F_HOME/.pi/agent/reviews/pending"
printf '%s\n' "$Q14C_MARKER" > "$PEND14"
Q14C_CAP="$T/flushcap14c"; : > "$Q14C_CAP"; : > "$LOG"
Q14C_RC=0
Q14C_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" STUB_CAPTURE="$Q14C_CAP" \
    STUB_BODY="A reviewer pasted this into their notes: $Q14C_MARKER — quoted mid-line" \
    bash "$RECORD" --flush-pending 424329 daniel-ospina/agent-infra 2>&1)" || Q14C_RC=$?
if grep -qF -- "-X PATCH" "$LOG"; then
    ok "14.10q a body that merely QUOTES the marker is not delivery — the flush PATCHed (transport, not an early return)"
else
    bad "14.10q the flush treated a QUOTED marker as delivered and did not PATCH (log: $(cat "$LOG")) — the pending marker would be deleted undelivered"
fi
if grep -qF -- '\n\nreview recorded: reviews/424329.json verdict=clean @ ' "$Q14C_CAP" 2>/dev/null; then
    ok "14.10q …and the delivered body carries the marker as its OWN line, which is what the gate anchors on"
else
    bad "14.10q the delivered body does not carry the marker as its own line — the gate would still refuse it"
fi
assert_eq "$Q14C_RC" "0" "14.10q the flush succeeds once it really delivers (rc 0)"
unset Q14C_MARKER Q14C_CAP Q14C_RC Q14C_OUT

# 14.10u AN UNSIGNED MARKER IS NEVER PUBLISHED AS A COMMENT (review round 2
#       finding 4: dropping the `MARKER_SIGNED` guard left the suite 974/0 green,
#       though the guard is a stated doctrine and it gates the exit-0/5 contract).
#       With no gate key the marker cannot be signed, so the comment channel must
#       not be used at all — not even attempted.
Q14E_CAP="$T/p1224-comment-8.json"; : > "$Q14E_CAP"
# ⛔ IT MUST REACH THE COMMENT STAGE (review round 3 finding 2). The first version of
# this vector minted a bare `clean` with NO `--evidence`, so it died at the
# tortoise#7391 guard (rc 3) and never built a marker — vacuous, and the guard it
# claimed to pin stayed removable with the suite green (measured). `--evidence`
# lets the mint proceed, and the transport assertion below proves the comment
# endpoint was never even called.
Q14E_RC=0
# ⛔ STUB_EVIDENCE_PR IS LOAD-BEARING (verification pass): without it the stub answers
# the evidence read with `parent: …/issues/0`, the tortoise#7391 guard refuses
# (`rc 3`) and NO marker is ever built — so the vector was satisfied by "nothing
# ever happened" and deleting the guard stayed green. Measured: with it set the mint
# proceeds (rc 0) and dropping the guard makes the comment POST (capture=138 bytes).
# The pass condition ALSO requires the mint to have happened, so the vector cannot
# go vacuous again silently.
Q14E_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" STUB_COMMENT_CAPTURE="$Q14E_CAP" \
    STUB_EVIDENCE_PR=424252 AI_REVIEW_GATE_KEY="" \
    bash "$RECORD" 424252 "$SHA" clean daniel-ospina/agent-infra --evidence comment:1 2>&1)" || Q14E_RC=$?
if [ "$Q14E_RC" = "0" ] && [ ! -s "$Q14E_CAP" ] && ! grep -qE "X POST repos/[^ ]*/issues/[0-9]+/comments" "$LOG"; then
    ok "14.10u an UNSIGNED marker is NOT published as a comment (mint succeeded, endpoint never called) — a comment cannot be retracted and an unsigned marker is never evidence"
else
    bad "14.10u the unsigned-marker rule did not hold (rc=$Q14E_RC — 3 means the mint never happened, so the vector proves nothing; capture=$([ -s "$Q14E_CAP" ] && echo yes || echo no), log: $(grep -oE 'X POST repos/[^ ]*/issues/[0-9]+/comments' "$LOG" | head -1)) — the gate can never accept an unsigned marker, and a published one cannot be undone"
fi
unset Q14E_CAP Q14E_RC Q14E_OUT

# 14.10d an EMPTY pending file is NOT a delivered marker (cycle-2 P1: the helper
#       used to `rm -f` it and return 0, so the flush claimed delivery and then
#       destroyed the only copy).
mkdir -p "$F_HOME/.pi/agent/reviews/pending"
: > "$PEND14"
: > "$LOG"
EMPTY_RC=0
EMPTY_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" STUB_BODY="PR body" \
    bash "$RECORD" --flush-pending 424329 daniel-ospina/agent-infra 2>&1)" || EMPTY_RC=$?
assert_eq "$EMPTY_RC" "5" "14.10d an EMPTY pending marker fails closed (rc 5) [out: $(printf '%s' "$EMPTY_OUT" | tr '\n' ' ')]"
if [ -f "$PEND14" ]; then ok "14.10d …and the (corrupt) pending file is KEPT, not silently deleted"; else bad "14.10d the empty pending file was deleted — the marker is now unrecoverable"; fi
if grep -qF -- "-X PATCH" "$LOG"; then bad "14.10d an empty marker was PATCHed (log: $(cat "$LOG"))"; else ok "14.10d …and nothing was posted"; fi
rm -f "$PEND14"
# 14.10e the gh-MISSING arm must not persist an empty marker (cycle-2 P1: MARKER is
#       built inside the gh-available block, so the old write persisted a 1-byte
#       file that a later flush "delivered" and deleted).
if declare -F run_record_no_gh >/dev/null 2>&1; then
    run_record_no_gh clean-micro "daniel-ospina/agent-infra" 424332 || true
    assert_eq "$RECORD_RC" "5" "14.10e with gh missing the record is written but the exit is a NAMED failure (rc 5) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
    assert_contains "$RECORD_ERR" "gh CLI is missing" "14.10e …and the message names the cause"
    # ⛔ AND IT MUST NOT CALL IT SIGNED (#3168 re-review, cycle 2): no gate key means
    #   nothing was signed, and MARKER is built inside the gh-available block, so on
    #   THIS arm no marker exists at all — "the signed marker" was false twice over.
    #   Pinned on the vector that already drives the arm, so the third instance of
    #   the class cannot come back unnoticed.
    assert_not_contains "$RECORD_ERR" "the signed marker" \
        "14.10e …and does not call a marker it never built 'the signed marker'"
    assert_contains "$RECORD_ERR" "so no marker for daniel-ospina/agent-infra#424332 was posted" \
        "14.10e …saying instead that no marker was posted (the honest state on this arm)"
    if [ -e "$F_HOME/.pi/agent/reviews/pending/daniel-ospina__agent-infra-424332.marker" ]; then
        bad "14.10e the gh-missing arm persisted a pending marker (it cannot have built one — MARKER is set inside the gh block)"
    else
        ok "14.10e …and no empty pending marker was persisted"
    fi
else
    # A GUARD WITH NO ELSE IS A FAIL-OPEN GATE (fresh-review cycle 3): renaming the
    # helper would delete this P1 pin silently, and the suite would still print a
    # summary. A skipped vector is a FAILURE, never a pass.
    bad "14.10e vector SKIPPED — run_record_no_gh is not defined; the empty-pending-marker pin did NOT run"
fi
assert_eq "$FL_RC" "0" "14.10b --flush-pending delivers the pending marker (rc 0) [out: $(printf '%s' "$FL_OUT" | tr '\n' ' ')]"
if [ -f "$PEND14" ]; then bad "14.10b the pending file survives a SUCCESSFUL flush (a retry would re-post forever)"; else ok "14.10b a successful flush clears the pending file"; fi
assert_eq "$REC_BEFORE_14B" "$(cat "$F_HOME/.pi/agent/reviews/daniel-ospina-agent-infra-424329.json")" "14.10b the flush does NOT re-record (the verdict and its reviewed_at are untouched)"
# 14.10f THE RECOVERY PATH'S PRESENCE PREDICATE — a **MAIN-REGRESSION** pin, not this
#       diff's fix (#3168 re-review finding 2). The behaviour it protects: a body that
#       merely CITES the marker mid-line must not read as "already present", because
#       then the flush PATCHes NOTHING, `rm -f`s the pending file, and the caller prints
#       "delivered the pending signed marker" — silent destruction of the only BODY copy
#       of the signed bytes, reported as success, reached not just by --flush-pending but
#       by EVERY later minting run.
#       ⛔ WHAT THIS ROW DOES **NOT** PROVE: that this PR anchored `post_marker()`. It did
#       not. `if command grep -qxF -- "$marker" <<<"$body"` is ALREADY `-qxF` on main
#       (`git show bd1b205d:scripts/record-review.sh | grep -n 'grep -qxF'` — the sha is NAMED
#       because `origin/main` moves and a bare "main :NNNN" rots the moment it does → :2482),
#       and in #3168's diff the only hunk at `post_marker()` (head :2714) ADDS A COMMENT above
#       it (this PR does not touch `post_marker()` at all) — the
#       predicate line (head :2736) is CONTEXT. Reverting #3168 leaves this vector GREEN; it is kept
#       because main's anchoring should not silently regress, and it is labelled so the
#       next reader does not mistake it for evidence about this diff. The predicate must
#       match the gate's line-anchored `^…$` admission, exactly like the three other
#       sites already anchored on main (bd1b205d :4186 :6501 :6613) — the same four that the grep
#       above prints at head, CITE-CHECK: :4462 :6832 :7006 (`14.1c-CITE` re-derives the triple).
#       ⛔ ASSERTS THE TRANSPORT (a PATCH was issued), not the exit code: the destructive
#       mutant also exited 0.
if [ -n "${QB_LINE:-}" ]; then
    PEND14F="$F_HOME/.pi/agent/reviews/pending/daniel-ospina__agent-infra-424340.marker"
    printf '%s\n' "$QB_LINE" > "$PEND14F"
    : > "$LOG"; F_CAP="$T/flushcap14f"; : > "$F_CAP"
    F_RC=0
    F_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" STUB_CAPTURE="$F_CAP" \
        STUB_BODY="A lane cited the attestation inline: $QB_LINE — see above." \
        bash "$RECORD" --flush-pending 424340 daniel-ospina/agent-infra 2>&1)" || F_RC=$?
    if grep -qF -- "-X PATCH" "$LOG"; then
        ok "14.10f flush: a body that only CITES the marker still gets the PATCH (anchored predicate)"
    else
        bad "14.10f flush: a mid-line marker SUPPRESSED the PATCH — a main regression to the unanchored -qF in post_marker()"
    fi
    if command grep -qxF -- "$QB_LINE" <<<"$(jq -r '.body // empty' "$F_CAP" 2>/dev/null)"; then
        ok "14.10f …and the delivered body carries the marker on a line of its OWN (gate-admissible)"
    else
        bad "14.10f the delivered body carries no anchored marker line"
    fi
    assert_eq "$F_RC" "0" "14.10f the flush succeeds (rc 0) [out: $(printf '%s' "$F_OUT" | tr '\n' ' ')]"
    if [ -f "$PEND14F" ]; then
        bad "14.10f a DELIVERED marker's pending file survives (a retry would re-post forever)"
    else
        ok "14.10f …and the delivered pending file is cleared"
    fi
else
    bad "14.10f vector SKIPPED — no seeded marker line; the main-regression post_marker() anchoring pin did NOT run"
fi
# 14.10c MUTATION PIN — the exit-5 rule must be load-bearing. With it reverted to
#       the old `exit 0`, a failed post reads as success again, which is exactly
#       the invisible-record state defect A reported.
FL_MUT="$T/record-review-a-mutant.sh"
cp "$RECORD" "$FL_MUT"
# ⛔ THE ANCHOR NAMES THE BRANCH, NOT THE ADJECTIVE (#3168 re-review, latest comment,
#   P2). It used to require the literal `the signed marker for … could NOT be
#   PATCHed`, so dropping the word "signed" from that message — correct, because this
#   arm is reachable with MARKER_SIGNED=0 — broke a MUTATION PIN that has nothing to do
#   with the adjective: a wording change must not be able to silently disarm a
#   behavioural pin, and re-anchoring it by hand every time is exactly the treadmill
#   this comment exists to avoid. `.*` spans the noun phrase; "could NOT be PATCHed
#   into the PR body" is unique to THIS arm (the body-READ arm says "was NOT written").
if grep -qE 'body-marker-unposted: .*could NOT be PATCHed into the PR body' "$FL_MUT"; then
    # The mutant restores the pre-fix behaviour on THAT branch only: warn and exit 0.
    # ⛔ ANCHORED TO THE BRANCH, AND THE SCOPE IS ASSERTED (fresh-review P2): two
    # lines in the script carry exactly six spaces before `exit 5` (this one and
    # --recover-body's refusal), so an address-free `s/^      exit 5$/…/` mutates
    # BOTH — a mutant wider than its declaration, whose extra change could mask a
    # fail-closed regression in later assertions.
    sed -i.bak '/body-marker-unposted: .*could NOT be PATCHed into the PR body/,/^      exit 5$/ s/^      exit 5$/      exit 0/' "$FL_MUT"
    rm -f "$FL_MUT.bak"
    if cmp -s "$RECORD" "$FL_MUT"; then
        bad "14.10c the mutant is byte-identical to the script — the exit-5 sed did not apply (re-anchor it)"
    fi
    # `diff` exits 1 ON DIFFERENCES, so the pipeline needs `|| true`: under
    # `set -euo pipefail` the assignment would abort the harness instead of
    # reporting the count (this bit once, and the suite reported a bare
    # "aborted BEFORE its summary").
    MUT_CHANGED="$( { diff "$RECORD" "$FL_MUT" || true; } | grep -c '^<' || true)"
    assert_eq "$MUT_CHANGED" "1" "14.10c the mutant changes EXACTLY one line (scope = the declared branch)"
    rm -f "$PEND14"
    RR633_SCRIPT="$FL_MUT" STUB_BODY="PR body — no review evidence yet" STUB_PATCH_FAIL=1 run_record_633 424331 "$SHA" '[]'
    if [ "$RECORD_RC" = "0" ] && ! grep -qF 'review recorded:' "$T/cap633" 2>/dev/null; then
        ok "14.10c MUTATION CAUGHT: with exit 5 reverted to exit 0 the post failure reads as SUCCESS while the body has no marker — so 14.10 is load-bearing"
    else
        bad "14.10c mutation NOT caught (rc=$RECORD_RC) — 14.10 cannot fail, so it proves nothing"
    fi
    rm -f "$F_HOME/.pi/agent/reviews/pending/daniel-ospina-agent-infra-424331.marker"
else
    bad "14.10c the mutation anchor (body-marker-unposted … could NOT be PATCHed) is gone — re-anchor the pin rather than dropping it"
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
#       §"Reading verification state" step 4, implemented by this file's `#633`
#       rerun predicate) is: only success/neutral/skipped are green and
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
#        named set only) — the same decision the `#633` rerun predicate makes.
#        (`target_head_red` was DELETED by #3440; cite the live predicate, never a
#        name that no longer exists in record-review.sh.)
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

# The repo root, so §20 can read the merge gate's OWN allowlist rather than a
# restatement of it (a copied list is how a new verdict drifts out of the gate).
REPO_ROOT="$(cd "$(dirname "$RECORD")/.." && pwd)"

# ═════════════════════════════════════════════════════════════════════════
# 20. #3400 — THE NEGATIVE VERDICT, AND RECENCY-AWARE MARKER READING
# ═════════════════════════════════════════════════════════════════════════
# The defect this section pins is a reviewed artifact moving under its record
# with nothing noticing. Three live instances in one night: a train whose head
# moved after its composite review, a composed tree that carried code REMOVING a
# fail-open fix, and tortoise#3295 whose body said `verdict=clean` while the most
# recent review at that head was NOT CLEAN. The last one survived because the
# recorder had NO negative verdict (agent-infra#3400) and the marker reader could
# not SEE a negative marker (agent-infra#3410): a `verdict=not-clean` line fell
# into RB_NBAD ("a marker whose signature does not verify"), so the keep-LAST rule
# — which already existed at the base commit, `1f69ab544:2521` — could never be
# given a negative to keep, and an earlier `clean` won by being the only readable
# marker. (Stated precisely: the delta is VISIBILITY, not recency. "Recency was
# presence-based" would be false — the recency rule was already there.)
#
# ⛔ EVERY ARM BELOW IS A DISCRIMINATOR, not a smoke test: 20.2 fails if recency
# handling is removed (first-marker-wins would recover `clean`), and 20.4 fails
# if `not-clean` grows a path that skips the evidence requirement `clean` has.
echo "── 20. #3400: the negative verdict + recency-aware marker reading ────────────"

# 20.0 THE MINT. A `not-clean` verdict must be RECORDABLE at all — that was the
# defect: the verdict list admitted clean|clean-micro|clean-low, so a review that
# found a defect could not be written down anywhere a gate reads.
NEG_F=1
run_record_neg() { # <pr> [extra args…]; $EV_REF names the artifact (empty ⇒ omit)
    local pr="$1"; shift
    local rcfile="$T/negrc" errfile="$T/negerr"
    rm -f "$errfile"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        rc=0
        if [ -n "${EV_REF:-}" ]; then
            bash "$RECORD" "$pr" "$SHA" not-clean "daniel-ospina/agent-infra" \
                --findings "${NEG_F:-1}" --evidence "$EV_REF" "$@" 2>"$errfile" || rc=$?
        else
            bash "$RECORD" "$pr" "$SHA" not-clean "daniel-ospina/agent-infra" \
                --findings "${NEG_F:-1}" "$@" 2>"$errfile" || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}
NEG_PR=424950
EV_REF="comment:42495001"
STUB_EVIDENCE_BODY='## Review — NOT CLEAN
1 open P2: the retry loop re-reads the claim after the lock is released.'
export STUB_EVIDENCE_BODY
run_record_neg "$NEG_PR"
assert_eq "$RECORD_RC" "0" "20.0 a not-clean verdict MINTS (rc 0) — before #3400 this was exit 2 and no record could exist"
NEG_REC="$(Q2 "$NEG_PR")"
if [ -f "$NEG_REC" ]; then ok "20.0 the negative record file is written"; else bad "20.0 no record written for not-clean"; fi
assert_contains "$(cat "$NEG_REC" 2>/dev/null)" '"verdict":"not-clean"' "20.0 the record carries verdict=not-clean"
assert_contains "$(cat "$NEG_REC" 2>/dev/null)" '"findings":1' "20.0 …and the FINDING COUNT, so the gate can say WHAT is open"
assert_contains "$(cat "$NEG_REC" 2>/dev/null)" "\"head_sha\":\"$SHA\"" "20.0 …bound to the head exactly as a clean record is"
assert_contains "$(cat "$NEG_REC" 2>/dev/null)" '"evidence":"comment:42495001"' "20.0 …and it names the VERIFIED artifact it rests on"
assert_contains "$RECORD_ERR" "review evidence verified" "20.0 …because the evidence gate actually RAN (not skipped by the negative verdict)"

# 20.1 THE GATE READS IT AS A FAILURE NAMING THE FINDING — not as "no record".
# The merge gate's allowlist (`extensions/review-enforcer::ACCEPTED_VERDICTS`) is
# the ONE place a verdict unlocks a merge, so a recorded negative must be ABSENT
# from it (recording one must never license a merge) while the gate's own
# not-clean branch names the head and the count (so a lane is not sent to "record
# a review" it already did, which is the "no record found" confusion).
ENF="$REPO_ROOT/extensions/review-enforcer/index.ts"
if [ -f "$ENF" ]; then
    ACC_LIST="$(command grep -n 'export const ACCEPTED_VERDICTS' "$ENF" | command head -1)"
    case "$ACC_LIST" in
        *not-clean*) bad "20.1 not-clean is in ACCEPTED_VERDICTS — recording a negative would license a merge" ;;
        *) ok "20.1 not-clean is NOT in the merge allowlist (a negative record blocks, as it must)" ;;
    esac
    command grep -q 'reviewed NOT CLEAN at' "$ENF" \
        && ok "20.1 the gate NAMES the finding (\"reviewed NOT CLEAN at <sha>: N open finding(s)\"), not \"no record found\"" \
        || bad "20.1 the gate has no not-clean branch — a recorded negative would read as an absent record"
    command grep -q 'record.findings' "$ENF" \
        && ok "20.1 …and it reads the recorded COUNT" \
        || bad "20.1 the gate never reads the recorded finding count"
else
    bad "20.1 fixture: extensions/review-enforcer/index.ts not found at $ENF"
fi

# 20.2 RECENCY. Two markers at the SAME head, `clean` FIRST and `not-clean`
# SECOND — the exact tortoise#3295 shape. The reader must take the LATEST one.
# ⛔ MUTATION PIN: with recency handling removed (keep-first, or a presence test
# that stops at the first match), the recovered record is `clean` and this arm
# FAILS. That is what makes it a discriminator rather than a smoke test.
rb_clear
NEG_HEAD="$(printf 'd%.0s' $(seq 1 40))"
NEG_DIFF="$(printf '7%.0s' $(seq 1 64))"
NEG_M_CLEAN="$(rb_marker 424952 "review recorded: reviews/424952.json verdict=clean @ $NEG_HEAD diff=$NEG_DIFF ($RB_REPO)")" \
  || bad "fixture: the clean marker could not be BUILT — 20.2 would otherwise fail on a missing marker"
NEG_M_NEG="$(rb_marker 424952 "review recorded: reviews/424952.json verdict=not-clean @ $NEG_HEAD diff=$NEG_DIFF ($RB_REPO) findings=2")" \
  || bad "fixture: the not-clean marker could not be BUILT — 20.2 would otherwise fail on a missing marker"
export STUB_BODY="Some PR description.

$NEG_M_CLEAN

$NEG_M_NEG"
run_recover 424952 "$RB_REPO"
NEG_REC2="$RB_RDIR/daniel-ospina-agent-infra-424952.json"
assert_eq "$RB_RC" "0" "20.2 a body with clean-then-not-clean recovers (exit 0)"
assert_contains "$(cat "$NEG_REC2" 2>/dev/null)" '"verdict":"not-clean"' \
  "20.2 the LATEST marker wins: verdict=not-clean, NOT the earlier clean (#3410)"
assert_contains "$(cat "$NEG_REC2" 2>/dev/null)" '"findings":2' \
  "20.2 …carrying the negative marker's own finding count"
if command grep -q '"verdict":"clean"' "$NEG_REC2" 2>/dev/null; then
    bad "20.2 the recovered record says clean — a later NOT CLEAN did not supersede it (recency handling missing)"
else
    ok "20.2 …and the superseded clean verdict is not in the record"
fi

# 20.3 REGRESSION GUARD — the negative verdict must not open a hole in the CLEAN
# path. §13f proves a clean mint over a NOT-CLEAN artifact refuses; this re-runs
# that pair AFTER a successful not-clean mint, because the (1b) declared-negative
# arm is the thing most likely to be refactored while adding a negative family.
#
# ⛔ WHAT THIS ARM DOES *NOT* PROVE (review, P3-3): it is NOT a (1b) discriminator.
# Its artifact carries NO `Outcome:` line, so the LOOSE arm (2) refuses it too on
# its own (`not[[:space:]_-]*clean`, unsuppressed) — delete arm (1b) entirely and
# this arm still goes green with rc 3. It is a guard that the CLEAN path still
# refuses at all, which is worth keeping and is all it claims. The pins that can
# ONLY pass through (1b) are §13n4/§13n5 (an `**Outcome: CLEAN …**` line, which
# SUPPRESSES arm (2), plus a declared NOT-CLEAN header) and §20.3b below, which is
# the same shape placed next to this arm so the claim and its pin travel together.
rb_clear
STUB_EVIDENCE_BODY='## Review — NOT CLEAN
2 P1s remain: unbounded retry, missing auth check.'
EV_REF="comment:42495301" run_record_ev 424953
assert_eq "$RECORD_RC" "3" "20.3 a CLEAN mint over a declared-negative artifact still REFUSES (rc 3) — arm (2) alone suffices here; the (1b) pin is 20.3b"
if [ -f "$(Q2 424953)" ]; then bad "20.3 the refused clean mint wrote a record"; else ok "20.3 …and writes nothing"; fi

# 20.4 `not-clean` DOES NOT BUY A CHEAPER PATH. It is held to `--evidence` exactly
# as `clean` is: without an artifact it must refuse with exit 3, or a lane could
# park a PR with a recorded negative it never earned.
rb_clear
EV_REF=""
run_record_neg 424954
assert_eq "$RECORD_RC" "3" "20.4 a not-clean mint with NO --evidence refuses (exit 3)"
if [ -f "$(Q2 424954)" ]; then bad "20.4 an unevidenced negative wrote a record"; else ok "20.4 …and writes nothing"; fi
assert_contains "$RECORD_ERR" "NEGATIVE verdict is still a claim" "20.4 …and says WHY a negative verdict needs evidence"

# 20.5 `--findings` is REQUIRED on not-clean and REFUSED elsewhere. Both are
# silently wrong otherwise: a negative with no count cannot be reported, and a
# clean record that swallowed a count looks like it recorded findings it cannot
# carry.
NEG_F=0
EV_REF="comment:42495501"
run_record_neg 424955
assert_eq "$RECORD_RC" "2" "20.5 --findings 0 is a contradiction and refuses (rc 2)"
if [ -f "$(Q2 424955)" ]; then bad "20.5 --findings 0 wrote a record"; else ok "20.5 …and writes nothing"; fi
NEG_F=1
run_record_raw 424956 "$SHA" clean "daniel-ospina/agent-infra" --findings 3 $EV_ARGS
assert_eq "$RECORD_RC" "2" "20.5 --findings on a CLEAN verdict is refused, not silently dropped (rc 2)"
assert_contains "$RECORD_ERR" "only meaningful with 'not-clean'" "20.5 …and names why"

# ── 20.6 (review P2-1) THE COUNT IS A CANONICAL JSON NUMBER, NOT A SPELLING ──
# The record writes `"findings":$FINDINGS` UNQUOTED, because every reader binds it
# as a JSON NUMBER (review-enforcer: `typeof record.findings === "number"`). So a
# zero-padded count is not cosmetic: `007` emits `"findings":007`, which does not
# parse, and the gate reads an unparseable record as NO RECORD — the #3400
# confusion, re-created by the feature that ends it.
#
# ⛔ THIS ARM FAILS ON THE PRE-FIX ARM AND CANNOT PASS BY ACCIDENT: before the fix
# `^[0-9]+$` accepted `007`, `[ 007 -lt 1 ]` was FALSE (bash reads a leading zero
# as octal) and the raw value was written straight through.
run_record_neg_cap() { # <pr> [extra args…] — the mint, CAPTURING the posted marker
    local pr="$1"; shift
    local rcfile="$T/negrc" errfile="$T/negerr" cap="$T/negcap"
    rm -f "$errfile"; : > "$cap"
    (
        export HOME="$F_HOME"
        export PATH="$T/bin:$PATH"
        export GH_STUB_LOG="$LOG"
        export STUB_CAPTURE="$cap"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        rc=0
        bash "$RECORD" "$pr" "$SHA" not-clean "daniel-ospina/agent-infra" \
            --findings "${NEG_F:-1}" --evidence "${EV_REF}" "$@" 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
    NEG_CAP="$(cat "$cap" 2>/dev/null || true)"
    # The PATCH sink holds the gh API ENVELOPE (`{"body":"…\n…"}`), whose marker
    # line is a `\n`-ESCAPED string rather than a line. Decode it: a round-trip has
    # to start from the body a reader of the PR would actually see.
    NEG_BODY="$(command python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$cap" 2>/dev/null || true)"
    [ -n "$NEG_BODY" ] || NEG_BODY="$NEG_CAP"
}
NEG_F=007
EV_REF="comment:42496001"
run_record_neg_cap 424961
assert_eq "$RECORD_RC" "0" "20.6 --findings 007 is ACCEPTED and NORMALISED, not written verbatim (rc 0)"
NEG_PAD_REC="$(Q2 424961)"
assert_contains "$(cat "$NEG_PAD_REC" 2>/dev/null)" '"findings":7,' "20.6 …the record carries the canonical integer 7"
if command grep -q '"findings":007' "$NEG_PAD_REC" 2>/dev/null; then
    bad "20.6 the record holds a ZERO-PADDED count — that is invalid JSON, and the gate would report 'No review record found'"
else
    ok "20.6 …and no zero-padded spelling reached the record"
fi
# ⛔ THE ASSERTION THAT ACTUALLY MATTERS: the record PARSES. A string comparison
# ( `grep` above) cannot tell a valid number from a token that only looks like one.
if command python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["findings"]==7 and isinstance(d["findings"],int) else 1)' "$NEG_PAD_REC" 2>"$T/negpy"; then
    ok "20.6 …and the record PARSES as JSON with findings==7 as a NUMBER (not a string)"
else
    bad "20.6 the record does not parse as JSON with an integer findings — the gate would read it as NO RECORD: $(command head -1 "$T/negpy" 2>/dev/null)"
fi
assert_contains "$NEG_CAP" " findings=7 " "20.6 …the posted marker carries the same canonical count"
# `08` is the case that made the OLD arm emit a bash error as well as a bad record:
# `[ 08 -lt 1 ]` aborts with "value too great for base".
NEG_F=08
run_record_neg_cap 424962
assert_eq "$RECORD_RC" "0" "20.6b --findings 08 (the octal-abort case) is accepted and normalised (rc 0)"
assert_contains "$(cat "$(Q2 424962)" 2>/dev/null)" '"findings":8,' "20.6b …recorded as the canonical integer 8"
# All-zero spellings are still the 'clean' contradiction, and are still refused.
NEG_F=00
run_record_neg_cap 424963
assert_eq "$RECORD_RC" "2" "20.6c --findings 00 is still the zero-findings contradiction (rc 2)"
if [ -f "$(Q2 424963)" ]; then bad "20.6c a zero count wrote a record"; else ok "20.6c …and writes nothing"; fi
# A NON-INTEGER is refused at the input arm, not normalised into existence.
NEG_F=1.5
run_record_neg_cap 424964
assert_eq "$RECORD_RC" "2" "20.6d --findings 1.5 (a float) is refused (rc 2)"
NEG_F=1

# ── 20.7 (review P3-2) A NOTE CANNOT REBIND THE RECOVERED HEAD ─────────────
# `--recover-body` used to read the head with a GREEDY `s/.* @ \([0-9a-f]\{40\}\).*/\1/p`,
# i.e. "the LAST ` @ <40hex>` in the line" — and the line carries the free-form
# `note=`. A note naming a sha ("also fails at @ <sha>", a plausible thing to
# write) therefore WON the match and the recovered record bound to a head the
# negative was never minted at.
#
# ⛔ THIS ARM FAILS ON THE PRE-FIX READER: measured, it recovered the NOTE's sha.
# The marker is SIGNED properly, so this is not an HMAC vector — it is the parse.
rb_clear
NEG_H_HEAD="$(printf 'b%.0s' $(seq 1 40))"
NEG_H_FAKE="$(printf 'a%.0s' $(seq 1 40))"
NEG_H_DIFF="$(printf '5%.0s' $(seq 1 64))"
NEG_M_HOSTILE="$(rb_marker 424965 "review recorded: reviews/424965.json verdict=not-clean @ $NEG_H_HEAD diff=$NEG_H_DIFF ($RB_REPO) findings=3 note=also fails at @ $NEG_H_FAKE")" \
  || bad "fixture: the hostile-note marker could not be BUILT — 20.7 would otherwise pass on a missing marker"
STUB_BODY="$NEG_M_HOSTILE"
run_recover 424965 "$RB_REPO"
NEG_H_REC="$RB_RDIR/daniel-ospina-agent-infra-424965.json"
assert_eq "$RB_RC" "0" "20.7 a not-clean marker whose NOTE names a sha still recovers (exit 0)"
assert_contains "$(cat "$NEG_H_REC" 2>/dev/null)" "\"head_sha\":\"$NEG_H_HEAD\"" \
  "20.7 the recovered head is the MINTED one, not the sha the note names"
if command grep -q "\"head_sha\":\"$NEG_H_FAKE\"" "$NEG_H_REC" 2>/dev/null; then
    bad "20.7 the record's HEAD bound to the note's sha — a hostile note moved the head (the greedy-sed defect)"
else
    ok "20.7 …and the note's sha is not the head the record binds"
fi
assert_contains "$(cat "$NEG_H_REC" 2>/dev/null)" '"findings":3' "20.7 …the finding count survives the hostile note"

# ── 20.8 (review P3-4) THE `--check-carry` NEGATIVE DIAGNOSIS AND THE note= ROUND-TRIP ──
# `cc_report_negative` / `cc_num_field` had ZERO assertions, so the arm that must
# stop a lane being told "land it" over an open finding rested on reading alone.
rb_clear
NEG_F=02
EV_REF="comment:42496601"
# `run_check_carry` reads the live head and the live diff from the fixture globals
# the 11.13 vectors set; this section owns its own, so a lane asking at the
# CURRENT head is the vector (the negative report must fire there too).
CC_HEAD="$SHA"
CC_DIFF="$T/neg-diff"
printf '%s\n' 'diff --git a/x b/x' > "$CC_DIFF"
run_record_neg_cap 424966
assert_eq "$RECORD_RC" "0" "20.8 fixture: the not-clean record mints (rc 0)"
run_check_carry 424966 "daniel-ospina/agent-infra"
assert_contains "$(cat "$T/cc-err" 2>/dev/null)" "reviewed NOT CLEAN at" \
  "20.8a --check-carry STATES the negative verdict (cc_report_negative) instead of advising 'land it' in silence"
assert_contains "$(cat "$T/cc-err" 2>/dev/null)" "2 open finding(s)" \
  "20.8b …naming the COUNT it read back with cc_num_field (--findings 02 normalised to 2)"
assert_contains "$(cat "$T/cc-err" 2>/dev/null)" "NOT a licence to merge" \
  "20.8c …and refusing the mis-reading: a carried negative is not a permission"
# cc_num_field reads an UNQUOTED JSON number and nothing else — the same binding the
# gate makes (`typeof record.findings === "number"`). A quoted count is therefore
# NOT a count, and the diagnosis must degrade to "no number" rather than print one.
rb_clear
CC_HEAD="$NEG_H_HEAD"
printf '%s\n' "{\"pr\":424967,\"head_sha\":\"$NEG_H_HEAD\",\"diff_sha256\":\"$NEG_H_DIFF\",\"verdict\":\"not-clean\",\"repo\":\"daniel-ospina/agent-infra\",\"findings\":\"4\"}" > "$(Q2 424967)"
run_check_carry 424967 "daniel-ospina/agent-infra"
assert_contains "$(cat "$T/cc-err" 2>/dev/null)" "reviewed NOT CLEAN at" \
  "20.8d a string-typed findings is still a negative verdict"
if command grep -q "open finding(s)" "$T/cc-err" 2>/dev/null; then
    bad "20.8d cc_num_field read a QUOTED findings — it must bind an unquoted number, as the gate does"
else
    ok "20.8d …and cc_num_field does NOT report a count it cannot bind as a number"
fi
# THE ROUND-TRIP: mint → posted marker → --recover-body, with the note intact.
rb_clear
NEG_F=3
EV_REF="comment:42496801"
run_record_neg_cap 424968 --findings-note "1 P2 + 2 P3"
assert_eq "$RECORD_RC" "0" "20.8e fixture: a not-clean record with --findings-note mints (rc 0)"
assert_contains "$(cat "$(Q2 424968)" 2>/dev/null)" '"findings_note":"1 P2 + 2 P3"' \
  "20.8e the record carries the note it was given"
assert_contains "$NEG_CAP" " note=1 P2 + 2 P3" "20.8e …and the POSTED marker carries it as the trailer"
rb_clear
STUB_BODY="$NEG_BODY"
run_recover 424968 "$RB_REPO"
assert_eq "$RB_RC" "0" "20.8f the minted marker RECOVERS on a box that lost the record (exit 0)"
assert_contains "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424968.json" 2>/dev/null)" '"findings_note":"1 P2 + 2 P3"' \
  "20.8f …with the note= ROUND-TRIPPED, not dropped"
assert_contains "$(cat "$RB_RDIR/daniel-ospina-agent-infra-424968.json" 2>/dev/null)" '"findings":3' \
  "20.8f …and the count alongside it"
unset NEG_CAP NEG_BODY STUB_BODY

# ── 20.9 (review P3-5) THE SECOND WRITER OF THE UNQUOTED COUNT ─────────────
# `--recover-body` writes `"findings":$RB_FINDINGS` — the SAME unquoted JSON number
# the mint writes, and for the same reason (every reader binds `typeof … ===
# "number"`) — but it filtered the marker's value with `*[!0-9]*` ONLY. So the
# P2-1 canonicaliser the mint holds was never applied on the second writer.
# Measured: `findings=007` (admissible by RB_RE's `findings=[0-9]+`) recovered to
# `"findings":007`, which does not parse, so the gate read NO RECORD — while the
# file now EXISTED, so the next recovery refused ("recovery fills an ABSENCE").
# A dead end needing manual removal, created by the one verb whose purpose is to
# avoid a dead end — strictly worse than the absent record it replaced.
#
# ⛔ THIS ARM FAILS ON THE PRE-FIX WRITER: `007` was written verbatim (the record
# does not parse) and `00` was written as `"findings":00` with exit 0, where the
# mint refuses a zero count outright ('not-clean' with zero findings IS 'clean').
rb_clear
NEG_Z_HEAD="$(printf 'e%.0s' $(seq 1 40))"
NEG_Z_DIFF="$(printf '6%.0s' $(seq 1 64))"
NEG_M_ZPAD="$(rb_marker 424970 "review recorded: reviews/424970.json verdict=not-clean @ $NEG_Z_HEAD diff=$NEG_Z_DIFF ($RB_REPO) findings=007")" \
  || bad "fixture: the zero-padded marker could not be BUILT — 20.9 would otherwise pass on a missing marker"
export STUB_BODY="$NEG_M_ZPAD"
run_recover 424970 "$RB_REPO"
NEG_Z_REC="$RB_RDIR/daniel-ospina-agent-infra-424970.json"
assert_eq "$RB_RC" "0" "20.9 a signed marker carrying findings=007 recovers (exit 0)"
assert_contains "$(cat "$NEG_Z_REC" 2>/dev/null)" '"findings":7,' "20.9 …writing the CANONICAL count 7, not the marker's spelling"
if command grep -q '"findings":007' "$NEG_Z_REC" 2>/dev/null; then
    bad "20.9 the recovered record holds a ZERO-PADDED count — invalid JSON, so the gate reads NO record while the file blocks the next recovery"
else
    ok "20.9 …and no zero-padded spelling reached the recovered record"
fi
# ⛔ THE ASSERTION THAT MATTERS: the record PARSES. `grep` cannot tell a valid
# number from a token that only looks like one — and the consequence a reader sees
# is a JSONDecodeError, then a permanent "a record already exists" refusal.
if command python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["findings"]==7 and isinstance(d["findings"],int) else 1)' "$NEG_Z_REC" 2>"$T/negzpy"; then
    ok "20.9 …and the recovered record PARSES as JSON with findings==7 as a NUMBER"
else
    bad "20.9 the recovered record does not parse as JSON with an integer findings — the gate would read it as NO RECORD: $(command head -1 "$T/negzpy" 2>/dev/null)"
fi
# The other half: `00` is not a count, it is the 'clean' contradiction. Recovery
# must REFUSE and leave NO file, or the refusal itself becomes the dead end.
rb_clear
NEG_M_ZERO="$(rb_marker 424971 "review recorded: reviews/424971.json verdict=not-clean @ $NEG_Z_HEAD diff=$NEG_Z_DIFF ($RB_REPO) findings=00")" \
  || bad "fixture: the zero-count marker could not be BUILT — 20.9b would otherwise pass on a missing marker"
export STUB_BODY="$NEG_M_ZERO"
run_recover 424971 "$RB_REPO"
assert_eq "$RB_RC" "3" "20.9b a marker carrying findings=00 is REFUSED (exit 3) — zero findings is what 'clean' means"
if [ -f "$(Q2 424971)" ]; then bad "20.9b a zero-count marker wrote a record"; else ok "20.9b …and writes nothing, so no unparseable file is left blocking the next recovery"; fi
unset STUB_BODY

# 20.3b REGRESSION GUARD, shape of 13n4/13n5 — the arm that ACTUALLY pins (1b).
# 20.3 above does NOT (review, P3-3): its artifact has no `Outcome:` line, so the
# loose arm (2) refuses it too and deleting (1b) leaves 20.3 green. The genuine
# (1b)-only shape is `**Outcome: CLEAN …**` PLUS a declared NOT-CLEAN header: the
# Outcome line SUPPRESSES arm (2), so only the declared-negative arm (1b) can
# refuse. This arm is 20.3's real discriminator, next to it so the claim and the
# pin travel together.
rb_clear
STUB_EVIDENCE_BODY='**Outcome: CLEAN — verified, no issues.**

## Review — NOT CLEAN
1 P1 remains: the retry loop re-reads the claim after the lock is released.'
EV_REF="comment:42496901" run_record_ev 424969
assert_eq "$RECORD_RC" "3" "20.3b (1b) refuses a CLEAN mint whose artifact declares NOT CLEAN even when an Outcome: CLEAN line suppresses arm (2) (rc 3)"
if [ -f "$(Q2 424969)" ]; then bad "20.3b the refused clean mint wrote a record"; else ok "20.3b …and writes nothing"; fi
assert_contains "$RECORD_ERR" "DECLARES a non-clean outcome" "20.3b …and names the declaration it refused on, which only (1b) can see"
NEG_F=1
EV_REF="comment:42495501"

# ─────────────────────────────────────────────────────────────────────────
# 21 #3440 — THE ATTESTATION PATH READS CI: the check surface on the recorded sha
# ─────────────────────────────────────────────────────────────────────────
# THE DEFECT. Nothing on the attestation path consulted CI. A PR could be reviewed
# clean, attested `clean`, and handed over as merge-ready while its head carried a
# FULLY RED check surface — MEASURED on #3355 (head 2823279e8…, 7 red: CI/bash-suites
# (3)…(8) and CI/verify): `record-review.sh 3355 <head> clean` printed ✅,
# `--check-carry` answered `head — nothing is stale and nothing needs re-review`, and
# the red was never read. A false PASS, category A.
#
# WHAT THIS SECTION PINS, and it is deliberately not "the code mentions check-runs":
#   21.1  control — a green surface still answers `head` (the change adds no block)
#   21.2  a PR-CAUSED red answers `red-surface` (7), NOT a licence — + MUTATION PIN
#   21.3  the SAME red, reproduced on the base, answers `red-base-owned` (0) and NAMES
#         the groups: "not silently tolerated" is the whole of #3440's item 3
#   21.4  a REFUSED read answers `surface-unknown` (8) — never a green one — + MUTATION PIN
#   21.5  an EMPTY surface is not green either (normal answer, loud on stderr)
#   21.6  the `carry` arm is gated too (the second licence-reading answer)
#   21.7  the RECORD carries the surface at mint — + MUTATION PIN (the issue's own
#         required mutant: drop the check-runs read and this must redden)
#   21.8  the fleet's own evidence gate is excluded (or minting would ALWAYS say red)
#   21.9  a hostile check name cannot break the record's JSON envelope
#   21.10 an unreadable/empty surface records `unknown`, never `green`
#   21.11 an UNPARSEABLE head row is never attributed to the base — + MUTATION PIN (the
#         fail-open a review of this change found: the sentinel matched itself)
#   21.12 the `carry` arm judges the LIVE head, not the recorded one — + MUTATION PIN
#   21.13 an IN-FLIGHT surface keeps the normal answer and says so (deliberate policy)
#   21.14 with NO repo resolvable the answer is surface-unknown (8), never a green
#   21.15 the surface fields are VOLATILE in the #1709 rec 7 identity — + MUTATION PIN
#   21.16 an UNREAD live head never answers from the RECORDED one — + 2 MUTATION PINS
#   21.17 an ALL-EXCLUDED surface is `empty`, never `green` — + MUTATION PIN (review of
#         `554d272`, P2: the early guard only caught an EMPTY RESPONSE)
#   21.18 an ambient RED_EXCLUDE cannot hide a red from the licence — + MUTATION PIN
#         (review of `988d0968`: a gate disabled by ambient env is category A)
# ⛔ THE EVIDENCE BODY IS A §20 FIXTURE (a deliberately NOT-CLEAN artifact, used to pin the
# falsified-evidence refusal) and the shared runner does not clear it, so every mint below
# would be refused with "the named review evidence could not be verified" — a decision about
# §20's subject, not about the surface. §21 owns its mints, so it clears it here.
unset STUB_EVIDENCE_BODY
echo "── 21 #3440: the attestation path reads CI (the check surface) ────"
S21_REPO="daniel-ospina/agent-infra"
S21_RDIR="$F_HOME/.pi/agent/reviews"
mkdir -p "$S21_RDIR"
S21_TAB="$(printf '\t')"
S21_HEAD="$(printf 'a%.0s' $(seq 1 40))"     # the stub's .head.sha — the LIVE head
S21_BASE="$(printf 'b%.0s' $(seq 1 40))"     # the PR's base, read via STUB_BASE_SHA
S21_FILE="$S21_RDIR/daniel-ospina-agent-infra"
S21_ROWS="$T/s21-rows"; mkdir -p "$S21_ROWS"
# ⛔ MUTANT COPIES LIVE IN $S21_MUTDIR, WITH `lib/` BESIDE THEM. `record-review.sh` resolves its
# one diff normalizer as `<dir of BASH_SOURCE>/lib/diff-normalize.py`; a copy dropped in `$T`
# therefore has no normalizer, degrades the diff read, and a diff-dependent mutant answers `fresh`
# for a reason unrelated to its mutation (measured: 21.12's first pin). Prepared once here.
S21_MUTDIR="$T/s21-mut"; mkdir -p "$S21_MUTDIR"
cp -r "$SCRIPT_DIR/lib" "$S21_MUTDIR/lib"
# SELF-CONTAINED digest fixtures (§11.13 unsets CC_SHA at :2974 — `grep -n '^unset CC_OUT CC_RC'` —, and the §11.12 note is
# explicit that a section leaning on another's fixture is either an abort under `set -u`
# or — worse — a silent comparison against bytes some other section computed). The
# digest comes from the ONE shared normalizer, exactly as the producer and the GitHub
# gate compute it.
S21_DIFF="$T/s21-real.diff"
printf 'diff --git a/docs/s21.md b/docs/s21.md\nindex 1111111..2222222 100644\n--- a/docs/s21.md\n+++ b/docs/s21.md\n@@ -1,3 +1,4 @@\n a\n+b\n c\n d\n' > "$S21_DIFF"
S21_SHA="$(python3 "$SCRIPT_DIR/lib/diff-normalize.py" < "$S21_DIFF" | openssl dgst -sha256 | awk '{print $NF}')"
S21_STALE="$(printf 'd%.0s' $(seq 1 40))"
# A head-bound record: no digest at all, which is the commonest healthy shape and the
# one that reaches the FIRST of the two licence-reading answers.
s21_rec() { # <pr> <head>
    printf '{"pr":%s,"head_sha":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
        "$1" "$2" "$S21_REPO" > "$S21_FILE-$1.json"
}
# TSV rows in the shape the recorder's own --jq asks gh for:
#   app.slug|name|id|status|conclusion
s21_rows() { # <file> <rows…>
    local f="$1"; shift
    printf '%s\n' "$@" > "$S21_ROWS/$f"
}
S21_GREEN='CI|bash-suites (3)|11|completed|success'
S21_GREEN2='CI|verify|12|completed|success'
S21_RED='CI|bash-suites (3)|11|completed|failure'
S21_RED2='CI|verify|12|completed|failure'
s21_run() { # <pr> <rows-head-file> <rows-base-file> [extra env assignments…] -> CC_RC/CC_OUT
    CC_RC=0
    CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 \
        STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
        STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
        bash "$RECORD" --check-carry "$1" "$S21_REPO" 2>"$T/s21-err")" || CC_RC=$?
}

# 21.1 CONTROL — a green surface changes nothing. Without this, every assertion below
# could pass on a verb that refuses unconditionally.
s21_rows "$S21_HEAD" "$S21_GREEN" "$S21_GREEN2"
s21_rows "$S21_BASE" "$S21_GREEN" "$S21_GREEN2"
s21_rec 425001 "$S21_HEAD"
s21_run 425001
assert_eq "$CC_RC" "0" "21.1 a GREEN surface still answers exit 0 (the change adds no block to a healthy head)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "head" "21.1 …and still reports 'head', so the healthy path is untouched"

# 21.2 A PR-CAUSED RED — the measured false PASS. The base is GREEN and the head is
# RED on the same group, so the red is this PR's. Answering `head` here would hand the
# owner a merge-ready attestation over a failing build, which is #3355 exactly.
s21_rows "$S21_HEAD" "$S21_RED" "$S21_RED2"
s21_rows "$S21_BASE" "$S21_GREEN" "$S21_GREEN2"
s21_rec 425002 "$S21_HEAD"
s21_run 425002
assert_eq "$CC_RC" "7" "21.2 a head-bound record over a PR-CAUSED red answers exit 7 (NOT mergeable)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "red-surface" "21.2 …with its own token, never 'head'"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "CI|bash-suites (3)" "21.2 …and NAMES the red group, so the operator sees what is failing"
# (a) MUTATION PIN — remove the gate call and the same fixture must answer `head`.
S21_MUT="$S21_MUTDIR/record-review-s21-nogate.sh"
cp "$RECORD" "$S21_MUT"
if grep -qF 'cc_surface_gate "$CC_HEAD" "${CC_DIFF:--}" "${DIFF_HASH:--}"' "$S21_MUT"; then
    sed -i.bak 's#^    cc_surface_gate "\$CC_HEAD" "\${CC_DIFF:--}" "\${DIFF_HASH:--}"$#    : no-gate#' "$S21_MUT"
    rm -f "$S21_MUT.bak"
    if cmp -s "$RECORD" "$S21_MUT"; then
        bad "21.2 mutation: the sed did not apply — re-anchor it rather than dropping the pin"
    else
        CC_RC=0
        CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
            STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
            STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
            bash "$S21_MUT" --check-carry 425002 "$S21_REPO" 2>/dev/null)" || CC_RC=$?
        if [ "$CC_RC" = "0" ] && [ "${CC_OUT%%"$S21_TAB"*}" = "head" ]; then
            ok "21.2 MUTATION PIN: with the surface gate removed the same fixture answers 'head'/0 — the gate is load-bearing"
        else
            bad "21.2 mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — 21.2 passes without the gate"
        fi
    fi
else
    bad "21.2 the mutation anchor 'cc_surface_gate …' is gone from the head arm — re-anchor the pin"
fi

# 21.3 THE SAME RED, REPRODUCED ON THE BASE. Every red group is also red on the base,
# so the PR did not cause it. The record still covers the artifact (exit 0, no review
# owed) but the answer is a DISTINCT token with the groups NAMED — item 3 of the issue:
# "not silently tolerated", even when the rail is the thing that will exempt it.
s21_rows "$S21_HEAD" "$S21_RED" "$S21_RED2"
s21_rows "$S21_BASE" "$S21_RED" "$S21_RED2"
s21_rec 425003 "$S21_HEAD"
s21_run 425003
assert_eq "$CC_RC" "0" "21.3 a BASE-OWNED red still covers the head (exit 0 — no review is owed for the base's red)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "red-base-owned" "21.3 …but NOT as 'head': a distinct token, so it is never a bare green"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "BASE-OWNED" "21.3 …and the diagnosis says BASE-OWNED in words"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "CI|verify" "21.3 …naming EVERY group being accepted, which is what the operator signs off on"

# 21.4 A REFUSED READ. The API call fails; a failed read is its OWN answer and must
# never be laundered into a green one (#2342's rule, applied to this question).
s21_rows "$S21_HEAD" "$S21_GREEN"
s21_rows "$S21_BASE" "$S21_GREEN"
s21_rec 425004 "$S21_HEAD"
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
    STUB_CHECKS_ROWS_DIR="$S21_ROWS" STUB_CHECKS_FAIL=1 \
    bash "$RECORD" --check-carry 425004 "$S21_REPO" 2>"$T/s21-err")" || CC_RC=$?
assert_eq "$CC_RC" "8" "21.4 an UNREADABLE surface answers exit 8 (not a licence, not a re-review)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "surface-unknown" "21.4 …with its own token"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "COULD NOT BE READ" "21.4 …and says the read failed rather than implying anything about the tree"
# (b) MUTATION PIN — a refused read must not fall through to the normal answer. The
# mutant removes the `unreadable)` arm's REFUSAL (its `exit 8` becomes `exit 0`), which is
# exactly the fail-open shape: the failed read still prints `surface-unknown`, and the
# caller that keys on the exit code reads it as a normal answer.
S21_MUT4="$S21_MUTDIR/record-review-s21-unreadable.sh"
cp "$RECORD" "$S21_MUT4"
if grep -q '^      unreadable)$' "$S21_MUT4"; then
    perl -0pi -e 's/(      unreadable\)\n(?:.*\n)*?        exit )8 \;\;/${1}0 ;;/' "$S21_MUT4"
    if cmp -s "$RECORD" "$S21_MUT4"; then
        bad "21.4 mutation: the perl rewrite did not apply — re-anchor the pin"
    else
        CC_RC=0
        CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
            STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
            STUB_CHECKS_ROWS_DIR="$S21_ROWS" STUB_CHECKS_FAIL=1 \
            bash "$S21_MUT4" --check-carry 425004 "$S21_REPO" 2>/dev/null)" || CC_RC=$?
        if [ "$CC_RC" = "0" ]; then
            ok "21.4 MUTATION PIN: with the unreadable arm's refusal removed the same failed read exits 0 — the arm produces the refusal"
        else
            bad "21.4 mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — something else is producing the exit 8"
        fi
    fi
else
    bad "21.4 the 'unreadable)' arm is gone — re-anchor the pin"
fi

# 21.5 AN EMPTY SURFACE IS NOT GREEN. It keeps the normal answer (a head whose checks
# have not attached yet must not be refused — that is the deadlock #2342 avoids) but it
# is LOUD, and the record below says `unknown`.
printf '' > "$S21_ROWS/$S21_HEAD"
s21_rec 425005 "$S21_HEAD"
s21_run 425005
assert_eq "$CC_RC" "0" "21.5 an EMPTY surface keeps the normal answer (no deadlock for a head whose checks have not attached)"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "NOT green" "21.5 …and is LOUD that absence is not green"
# restore for the remaining arms
s21_rows "$S21_HEAD" "$S21_GREEN" "$S21_GREEN2"

# 21.6 THE CARRY ARM IS GATED TOO. `carry` is the second answer that reads as a licence
# ("do NOT re-review … land it"), so it must not be printable over a red tree either.
# ⛔ THE ROWS GO ON THE LIVE HEAD: the answer this arm publishes is a LICENCE ("the reviewed
# diff is unchanged — land it") and the head that lands is the LIVE one, so that is the surface
# judged. (The first version of this fixture reddened the RECORDED head and passed — for the
# wrong reason: the arm was judging the recorded head at the time.)
# ⛔ THE RED GOES ON THE **LIVE** HEAD. Since review round 2 the carry arm judges the head that
# would MERGE (the live one) — see §21.12 for the recorded-head-is-green case, which is the
# separate and sharper vector.
s21_rows "$S21_HEAD" "$S21_RED" "$S21_RED2"
s21_rows "$S21_STALE" "$S21_GREEN" "$S21_GREEN2"
s21_rows "$S21_BASE" "$S21_GREEN" "$S21_GREEN2"
printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
    "425006" "$(printf 'd%.0s' $(seq 1 40))" "$S21_SHA" "$S21_REPO" > "$S21_FILE-425006.json"
s21_run 425006
assert_eq "$CC_RC" "7" "21.6 the 'carry' arm is gated too: an unchanged diff over a red head answers exit 7"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "red-surface" "21.6 …never 'carry' (which merge-one reads as 'no review ordered')"

# 21.11 THE UNPARSEABLE-ROW SENTINEL IS NEVER ATTRIBUTABLE — the fail-open a review of this
# change FOUND (round 1, blocking). `check_surface_scan` emits `?|(unparseable row)` for a row
# it cannot group, and the BASE scan emits the SAME STRING whenever ITS rows are unparseable —
# including when those rows are GREEN. A plain name-comparison therefore matched the sentinel
# against itself, `owned == total` held, and a PR-CAUSED red answered `red-base-owned` (exit 0),
# which merge-one carries and check (c) passes. That is the exact false PASS #3440 exists to
# close, reached through the attribution instead of through the surface.
# THE SHAPE MEASURED: a head row whose NAME carries a literal pipe (`shard 1 | slow`), and a
# base row that is the same job and is SUCCESS — piped, so equally unparseable.
s21_rows "$S21_HEAD" 'CI|shard 1 | slow|11|completed|failure'
s21_rows "$S21_BASE" 'CI|shard 1 | slow|11|completed|success'
s21_rec 425011 "$S21_HEAD"
s21_run 425011
assert_eq "$CC_RC" "7" "21.11 an UNPARSEABLE head row over a PIPED-BUT-GREEN base is red-surface (7), never base-owned"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "red-surface" "21.11 …never 'red-base-owned' (the sentinel must not match itself)"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "unattributable" "21.11 …and the diagnosis says the row could not be attributed"
# (c) MUTATION PIN — the guard is what makes that true. Drop it and the same fixture answers
# `red-base-owned`/0, i.e. the PR-caused red becomes mergeable again.
S21_MUT11="$S21_MUTDIR/record-review-s21-sentinel.sh"
cp "$RECORD" "$S21_MUT11"
if grep -qF -- 'if [ "$k" = "?|(unparseable row)" ]; then' "$S21_MUT11"; then
    sed -i.bak 's#^      if \[ "\$k" = "?|(unparseable row)" \]; then$#      if false; then#' "$S21_MUT11"
    rm -f "$S21_MUT11.bak"
    if cmp -s "$RECORD" "$S21_MUT11"; then
        bad "21.11 mutation: the sed did not apply — re-anchor the pin"
    else
        CC_RC=0
        CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
            STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
            STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
            bash "$S21_MUT11" --check-carry 425011 "$S21_REPO" 2>/dev/null)" || CC_RC=$?
        if [ "$CC_RC" = "0" ] && [ "${CC_OUT%%"$S21_TAB"*}" = "red-base-owned" ]; then
            ok "21.11 MUTATION PIN: without the sentinel guard the same PR-caused red answers 'red-base-owned'/0 — the guard is load-bearing"
        else
            bad "21.11 mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — the guard is not what produces 21.11"
        fi
    fi
else
    bad "21.11 the sentinel guard is gone — re-anchor the pin"
fi

# 21.12 THE `carry` ARM JUDGES THE **LIVE** HEAD — review round 2, BLOCKING. In that arm the
# recorded head and the live head differ BY CONSTRUCTION, and the head that MERGES is the live one:
# the ordinary `gh pr update-branch` / base-refresh shape is "diff unchanged, new head, CI re-runs".
# The first version judged the RECORDED head, so a green recorded head with a RED live head answered
# `carry`/0 — check (c) passed and merge-one went looking for a 20-40 minute review over a red tree.
s21_rows "$S21_STALE" "$S21_GREEN" "$S21_GREEN2"     # the reviewed head is green
s21_rows "$S21_HEAD"  "$S21_RED" "$S21_RED2"         # the LIVE head is red
s21_rows "$S21_BASE"  "$S21_GREEN" "$S21_GREEN2"
printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
    "425012" "$S21_STALE" "$S21_SHA" "$S21_REPO" > "$S21_FILE-425012.json"
s21_run 425012
assert_eq "$CC_RC" "7" "21.12 a RED LIVE head over an unchanged diff answers exit 7 (the head that merges is the one judged)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "red-surface" "21.12 …never 'carry' (which reads as 'land it')"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "${S21_HEAD:0:12}" "21.12 …and the diagnosis names the LIVE sha, so the operator can see which head is red"
# (d) MUTATION PIN — judging the recorded head instead puts the licence back.
S21_MUT12="$S21_MUTDIR/record-review-s21-recordedsha.sh"
cp "$RECORD" "$S21_MUT12"
if grep -qF -- 'cc_surface_gate "$CC_LIVE_HEAD" "$CC_DIFF" "$DIFF_HASH"' "$S21_MUT12"; then
    sed -i.bak 's#^    cc_surface_gate "\$CC_LIVE_HEAD" "\$CC_DIFF" "\$DIFF_HASH"$#    cc_surface_gate "$CC_HEAD" "$CC_DIFF" "$DIFF_HASH"#' "$S21_MUT12"
    rm -f "$S21_MUT12.bak"
    if cmp -s "$RECORD" "$S21_MUT12"; then
        bad "21.12 mutation: the sed did not apply — re-anchor the pin"
    else
        CC_RC=0
        CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
            STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
            STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
            bash "$S21_MUT12" --check-carry 425012 "$S21_REPO" 2>/dev/null)" || CC_RC=$?
        if [ "$CC_RC" = "0" ] && [ "${CC_OUT%%"$S21_TAB"*}" = "carry" ]; then
            ok "21.12 MUTATION PIN: judging the RECORDED head answers 'carry'/0 over the same red live head — the live-head choice is load-bearing"
        else
            bad "21.12 mutation NOT caught (rc=$CC_RC, out=$CC_OUT)"
        fi
    fi
else
    bad "21.12 the carry arm's gate call is gone — re-anchor the pin"
fi

# 21.16 AN UNREAD LIVE HEAD IS NEVER ANSWERED FROM THE RECORDED ONE — review of `988d0968`,
# BLOCKING. The `carry` arm is the second answer that reads as a LICENCE ("Do NOT re-review …
# land it"), and the population it exists for is exactly "the head moved, the reviewed diff did
# not". The head IDENTITY read is a SINGLE un-retried `gh` call while the diff read retries
# `DIFF_FETCH_ATTEMPTS` times, so "diff readable / head unreadable" is the ordinary degradation,
# not the exotic one — and the arm used to substitute the RECORDED head for the unread one. That
# is round 2's BLOCKING shape reached again through the identity read: a GREEN recorded head over
# a head whose surface was never read answered `carry`/0, which check (c) reads as a PASSING
# required check and `merge-one.sh`'s RECORD-RECOVERY arm reads as "no review owed".
# HERE the recorded head IS green and the LIVE head is NOT READABLE (`gh` answers `null`, the
# API's own shape for an unresolvable ref), so the only correct answer is `surface-unknown`/8.
s21_rows "$S21_STALE" "$S21_GREEN" "$S21_GREEN2"   # the recorded head's surface: GREEN
s21_rows "$S21_BASE"  "$S21_GREEN" "$S21_GREEN2"
printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
    "425020" "$S21_STALE" "$S21_SHA" "$S21_REPO" > "$S21_FILE-425020.json"
# The ABSENCE assertion below must not see a prior vector's check-runs calls (the §13a idiom).
s21_unread() { # <script> -> CC_RC/CC_OUT, with the LIVE head UNREADABLE
    CC_RC=0
    CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
        STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="null" STUB_BASE_SHA="$S21_BASE" \
        STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
        bash "$1" --check-carry 425020 "$S21_REPO" 2>"$T/s21-err")" || CC_RC=$?
}
: > "$LOG"
s21_unread "$RECORD"
assert_eq "$CC_RC" "8" "21.16 an UNREAD live head answers exit 8 (a failed read is not a carry)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "surface-unknown" "21.16 …never 'carry', which reads as 'land it'"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "LIVE head could not be READ" "21.16 …and the diagnosis names the unread LIVE head, so an operator is not sent at the record"
if grep -qF -- "commits/$S21_STALE/check-runs" "$LOG" 2>/dev/null; then
    bad "21.16 the RECORDED head's check surface was READ — it is not the head that merges, so its green certifies nothing about the merge"
else
    ok "21.16 …and the RECORDED head's surface is never read (its green would be a licence for a sha nobody read)"
fi
# (f) MUTATION PIN — THE PRE-FIX CODE, EXACTLY: the guard removed AND the recorded head
# substituted for the unread one. This is the fail-open the finding names ("silently falls back to
# the record"), so the pin asserts the OLD answer rather than merely "something else happened".
# ⛔ THE TWO seds ARE ASSERTED INDIVIDUALLY, AND THE LICENCE'S SOURCE IS PART OF THE PIN (fresh
# review of 1cc874984, P2). A single `cmp` against the original cannot tell a TWO-PART mutation from
# a one-part one, and the one-part mutant (guard removed, gate call untouched) ALSO answers
# `carry`/0 — for a different reason: a blank sha reaches `cc_surface_gate` and the scan's EMPTY arm
# is a PASS (#2342), which is what pin (b) covers. Measured: with only the guard sed applied, this
# pin printed its "the substitution IS the fail-open" line while the substitution was not present.
# So the ok requires BOTH rewrites AND that the run actually READ the RECORDED head's check surface
# — that read is the proof the green came from the record and not from the blank-sha pass.
S21_MUT16A="$S21_MUTDIR/record-review-s21-unreadfallback.sh"
cp "$RECORD" "$S21_MUT16A"
sed -i.bak 's#^  if \[ -z "\$CC_LIVE_HEAD" \]; then$#  if false; then#' "$S21_MUT16A"
sed -i.bak 's#^    cc_surface_gate "\$CC_LIVE_HEAD" "\$CC_DIFF" "\$DIFF_HASH"$#    cc_surface_gate "${CC_LIVE_HEAD:-$CC_HEAD}" "$CC_DIFF" "$DIFF_HASH"#' "$S21_MUT16A"
rm -f "$S21_MUT16A.bak"
if grep -qF -- 'if [ -z "$CC_LIVE_HEAD" ]; then' "$S21_MUT16A" \
   || ! grep -qF -- 'cc_surface_gate "${CC_LIVE_HEAD:-$CC_HEAD}" "$CC_DIFF" "$DIFF_HASH"' "$S21_MUT16A"; then
    bad "21.16(a) mutation: the TWO-PART pre-fix rewrite did not apply (the guard must be GONE and the fallback RESTORED) — re-anchor the pin"
else
    : > "$LOG"
    s21_unread "$S21_MUT16A"
    if [ "$CC_RC" = "0" ] && [ "${CC_OUT%%"$S21_TAB"*}" = "carry" ] \
       && grep -qF -- "commits/$S21_STALE/check-runs" "$LOG" 2>/dev/null; then
        ok "21.16(a) MUTATION PIN: restoring the fallback over an UNREAD live head answers 'carry'/0 AND the run reads the RECORDED head's check surface — the recorded-head substitution IS the fail-open"
    else
        bad "21.16(a) mutation NOT caught (rc=$CC_RC, out=$CC_OUT, recorded-head check-runs reads=$(grep -cF -- "commits/$S21_STALE/check-runs" "$LOG" 2>/dev/null)) — either the answer is not 'carry'/0 or the licence did not come from the RECORDED head"
    fi
fi
# (g) AND THE GUARD ALONE IS LOAD-BEARING — not merely "we happen to pass the right variable".
# With only the guard deleted, `cc_surface_gate ""` is what runs; the scan's `empty` arm is a PASS
# (#2342), so the same stub answers `carry`/0 — and the log shows the BLANK-SHA url, which is what
# proves the licence came from the empty pass and not from the record. Correctness must not rest on
# the real API turning a blank sha into a 422 — measured here so the guard cannot be tidied away as
# redundant.
S21_MUT16B="$S21_MUTDIR/record-review-s21-noguard.sh"
cp "$RECORD" "$S21_MUT16B"
sed -i.bak 's#^  if \[ -z "\$CC_LIVE_HEAD" \]; then$#  if false; then#' "$S21_MUT16B"
rm -f "$S21_MUT16B.bak"
if grep -qF -- 'if [ -z "$CC_LIVE_HEAD" ]; then' "$S21_MUT16B" \
   || ! grep -qF -- 'cc_surface_gate "$CC_LIVE_HEAD" "$CC_DIFF" "$DIFF_HASH"' "$S21_MUT16B"; then
    bad "21.16(b) mutation: the sed did not apply — re-anchor the pin"
else
    : > "$LOG"
    s21_unread "$S21_MUT16B"
    if [ "$CC_RC" = "0" ] && [ "${CC_OUT%%"$S21_TAB"*}" = "carry" ] \
       && grep -qF -- "commits//check-runs" "$LOG" 2>/dev/null; then
        ok "21.16(b) MUTATION PIN: without the guard the BLANK sha reaches cc_surface_gate and the same unread head answers 'carry'/0 via the scan's empty pass — the refusal is OURS, not the transport's"
    else
        bad "21.16(b) mutation NOT caught (rc=$CC_RC, out=$CC_OUT) — the guard is not what produces 21.16"
    fi
fi

# 21.15 THE SURFACE FIELDS ARE VOLATILE IN THE #1709 rec 7 IDENTITY — review round 3, coverage.
# A record re-minted at the SAME head that observes a DIFFERENT surface (red → green after a re-run)
# must be a NO-OP: `reviewed_at` is the audit trail's only join to the authorising dispatch, and a
# refresh must not move it. If either strip in `record_identity` is dropped, the second mint is
# treated as a NEW record, rewrites the file and re-stamps `reviewed_at` — and nothing else in this
# suite notices, because every other mint is one per PR.
s21_rows "$S21_HEAD" "$S21_RED"
rm -f "$S21_FILE-425015.json"
export STUB_CHECKS_ROWS_DIR="$S21_ROWS"
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425015
S21_REC15A="$(cat "$S21_FILE-425015.json" 2>/dev/null || echo)"
assert_contains "$S21_REC15A" '"check_surface":"red"' "21.15 fixture: the first mint records the RED surface"
S21_AT15="$(printf '%s' "$S21_REC15A" | sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p')"
sleep 1
s21_rows "$S21_HEAD" "$S21_GREEN" "$S21_GREEN2"
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425015
S21_REC15B="$(cat "$S21_FILE-425015.json" 2>/dev/null || echo)"
assert_contains "$(printf '%s' "$S21_REC15B" | sed -n 's/.*"check_surface":"\([^"]*\)".*/\1/p')" "red" \
  "21.15 a re-mint at the same head with a CHANGED surface is a #1709 rec 7 NO-OP (the first observation stands)"
assert_contains "$(printf '%s' "$S21_REC15B" | sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p')" "$S21_AT15" \
  "21.15 …and reviewed_at did NOT move (the audit join is preserved)"
assert_contains "$(printf '%s' "$RECORD_ERR" | command tr '\n' '|')" "idempotent" \
  "21.15 …and the recorder SAYS it was a no-op, so the state is diagnosable"
# (e) MUTATION PIN — drop the strip and the second mint rewrites the record.
# ⛔ THE MUTANT IS BUILT WITH `grep -vF` ON A FIXED STRING, not a sed script: the line being
# removed is itself full of shell/regex metacharacters (`'`, `"`, `[^"]*`), and a sed address
# written to match it is a parsing puzzle rather than a test. Fixed-string deletion is exact.
S21_MUT15="$S21_MUTDIR/record-review-s21-nostrip.sh"
S21_STRIP_PAT='-e '"'"'s/"check_surface":"[^"]*",//'"'"''
if grep -qF -- "$S21_STRIP_PAT" "$RECORD"; then
    grep -vF -- "$S21_STRIP_PAT" "$RECORD" > "$S21_MUT15"
    if cmp -s "$RECORD" "$S21_MUT15"; then
        bad "21.15 mutation: the fixed-string deletion did not apply — re-anchor the pin"
    else
        s21_rows "$S21_HEAD" "$S21_RED"
        rm -f "$S21_FILE-425016.json"
        EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425016
        s21_rows "$S21_HEAD" "$S21_GREEN" "$S21_GREEN2"
        S21_REC16A="$(cat "$S21_FILE-425016.json" 2>/dev/null || echo)"
        S21_AT16="$(printf '%s' "$S21_REC16A" | sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p')"
        sleep 1
        S21_SAVE="$RECORD"
        RECORD="$S21_MUT15"
        EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425016
        RECORD="$S21_SAVE"
        S21_REC16B="$(cat "$S21_FILE-425016.json" 2>/dev/null || echo)"
        if [ "$(printf '%s' "$S21_REC16B" | sed -n 's/.*"check_surface":"\([^"]*\)".*/\1/p')" = "green" ]; then
            ok "21.15 MUTATION PIN: with the strip removed the same head is RE-MINTED (surface rewritten to green) — the volatility rule is load-bearing"
        else
            bad "21.15 mutation NOT caught (record still: $(printf '%s' "$S21_REC16B" | command head -c 160))"
        fi
    fi
else
    bad "21.15 the record_identity strip is gone — re-anchor the pin"
fi

# 21.13 IN FLIGHT is a deliberate POLICY (it keeps the normal answer and says so). Pinned because
# flipping it either way is invisible to every other assertion: refusing would deadlock every lane
# that asks mid-CI, and silence would be the bare green #3440 exists to end.
s21_rows "$S21_HEAD" 'CI|bash-suites (3)|11|in_progress|null' 'CI|verify|12|completed|success'
s21_rec 425013 "$S21_HEAD"
s21_run 425013
assert_eq "$CC_RC" "0" "21.13 an IN-FLIGHT surface keeps the normal answer (refusing would deadlock every lane that asks mid-CI)"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "IN FLIGHT" "21.13 …and says IN FLIGHT, never reading an unfinished surface as green"

# 21.14 NO REPO RESOLVED is a REFUSAL, not a pass — the check-runs query is repo-scoped, and a PR
# number alone does not name one. Pinned because it is the only surface outcome whose remedy is
# "pass the repo", and nothing else in the suite reaches it.
s21_rows "$S21_HEAD" "$S21_GREEN" "$S21_GREEN2"
s21_rec 425014 "$S21_HEAD"
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
    STUB_CHECKS_ROWS_DIR="$S21_ROWS" STUB_REPO_NAME="" \
    bash "$RECORD" --check-carry 425014 2>"$T/s21-err")" || CC_RC=$?
assert_eq "$CC_RC" "8" "21.14 with NO repo resolvable the surface cannot be read, so the answer is exit 8 (never a green)"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "Pass it positionally" "21.14 …and the remedy names the argument to pass"

# ── 21.7–21.10: THE MINT PATH ─────────────────────────────────────────────
# The record must SAY what the surface was when the verdict was recorded. This is the
# half that makes the datum readable AFTER the fact — `--check-carry` deliberately
# re-reads LIVE instead of trusting a stored flag.
s21_rows "$S21_HEAD" "$S21_RED"
rm -f "$S21_FILE-425007.json"   # the MINT under test must create it: a pre-existing record
# with the same deterministic identity makes the mint a #1709 rec 7 NO-OP, so the file would
# keep the shape below and the assertion would measure nothing.
export STUB_CHECKS_ROWS_DIR="$S21_ROWS"
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425007
S21_REC7="$(cat "$S21_FILE-425007.json" 2>/dev/null || echo)"
if [ ! -s "$S21_FILE-425007.json" ]; then
    bad "21.7 fixture: the mint wrote NO record (rc=$RECORD_RC, err=$(printf '%s' "$RECORD_ERR" | command head -12 | command tr '\n' '|'))"
fi
assert_contains "$S21_REC7" '"check_surface":"red"' "21.7 a mint at a RED head records check_surface=red (the fact is in the artifact, not just on stderr)"
assert_contains "$S21_REC7" '"check_surface_red":"CI|bash-suites (3)' "21.7 …and names the red group, so a later reader can see WHAT was red"
assert_contains "$(printf '%s' "$S21_REC7" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("check_surface",""))' 2>/dev/null)" "red" "21.7 …and the record still PARSES as JSON (the field cannot break the envelope)"

# (c) THE ISSUE'S OWN REQUIRED MUTANT: drop the check-runs read from the mint path.
S21_MUT7="$S21_MUTDIR/record-review-s21-noread.sh"
cp "$RECORD" "$S21_MUT7"
if grep -q 'SURFACE_CELL="$(check_surface_scan "$SHA" 2>/dev/null)" || SURFACE_CELL="unreadable"' "$S21_MUT7"; then
    sed -i.bak 's#SURFACE_CELL="$(check_surface_scan "$SHA" 2>/dev/null)" || SURFACE_CELL="unreadable"#SURFACE_CELL="green"#' "$S21_MUT7"
    rm -f "$S21_MUT7.bak"
    if cmp -s "$RECORD" "$S21_MUT7"; then
        bad "21.7 mutation: the sed did not apply — re-anchor it rather than dropping the pin"
    else
        printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
            "425017" "$S21_HEAD" "$S21_SHA" "$S21_REPO" > "$S21_FILE-425017.json"
        # ⛔ THE MUTANT IS DRIVEN BY POINTING `RECORD` AT IT, restored immediately after:
        # an `VAR=… run_record …` prefix on a FUNCTION persists in bash, which makes the
        # restore easy to get wrong and leaves every LATER section running the mutant.
        S21_RECORD_SAVE="$RECORD"
        RECORD="$S21_MUT7"
        EV_REF="comment:7391001" run_record "$S21_REPO" 425017
        RECORD="$S21_RECORD_SAVE"
        S21_REC17="$(cat "$S21_FILE-425017.json" 2>/dev/null || echo)"
        # ⛔ NO PIPE (#841/#864) — here-string, the transform the exceptions file records.
        if grep -q '"check_surface":"green"' <<<"$S21_REC17"; then
            ok "21.7 MUTATION PIN: with the check-runs read dropped the record says check_surface=green over the SAME red head — the read is load-bearing"
        else
            bad "21.7 mutation NOT caught (record: $S21_REC17) — 21.7 would pass on a mutant that never reads CI"
        fi
    fi
else
    bad "21.7 the mint-path surface read is gone — re-anchor the pin (this is #3440's required mutant)"
fi

# 21.8 THE FLEET'S OWN EVIDENCE GATE IS EXCLUDED — and this is LOAD-BEARING, not tidiness:
# `ai-review-gate` is red precisely BECAUSE the evidence is not recorded yet, so at mint
# time it is ALWAYS red. Counting it would make every fresh record say `red` and every
# `--check-carry` after it refuse — the change would convert the whole attestation path
# into a no-op. One green group + the gate red must therefore record `green`.
s21_rows "$S21_HEAD" "$S21_GREEN" 'ai-review-gate|ai-review-gate|99|completed|failure'
rm -f "$S21_FILE-425008.json"   # the MINT under test must create it: a pre-existing record
# with the same deterministic identity makes the mint a #1709 rec 7 NO-OP, so the file would
# keep the shape below and the assertion would measure nothing.
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425008
S21_REC8="$(cat "$S21_FILE-425008.json" 2>/dev/null || echo)"
if [ ! -s "$S21_FILE-425008.json" ]; then
    bad "21.8 fixture: the mint wrote NO record (rc=$RECORD_RC, err=$(printf '%s' "$RECORD_ERR" | tail -3))"
fi
assert_contains "$S21_REC8" '"check_surface":"green"' "21.8 the fleet's own evidence gate is EXCLUDED (a gate red for stale evidence must not brand every fresh record red)"

# 21.9 A HOSTILE CHECK NAME CANNOT BREAK THE ENVELOPE. A workflow name is repo content,
# so a quote or a backslash in it would truncate the one-line JSON — and the gate reads
# an unparseable record as NO RECORD (#3400's failure mode).
s21_rows "$S21_HEAD" 'CI|evil"name\here|11|completed|failure'
rm -f "$S21_FILE-425009.json"   # the MINT under test must create it: a pre-existing record
# with the same deterministic identity makes the mint a #1709 rec 7 NO-OP, so the file would
# keep the shape below and the assertion would measure nothing.
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425009
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["check_surface"]=="red" else 1)' "$S21_FILE-425009.json" 2>/dev/null; then
    ok "21.9 a check name carrying quote/backslash still yields a PARSEABLE record with check_surface=red"
else
    bad "21.9 the hostile check name broke the record: $(cat "$S21_FILE-425009.json" 2>/dev/null | command head -c 200)"
fi

# 21.10 AN UNREADABLE SURFACE RECORDS `unknown`, NEVER `green`. Item 4 of the issue:
# a surface that cannot be read is not green, and the record must say so.
rm -f "$S21_FILE-425010.json"   # the MINT under test must create it: a pre-existing record
# with the same deterministic identity makes the mint a #1709 rec 7 NO-OP, so the file would
# keep the shape below and the assertion would measure nothing.
CC_RC=0
# A REFUSED read is an ENV effect, so it is exported rather than passed as a command
# prefix: `VAR=… run_record_rc …` on a FUNCTION persists in bash and would leak the failure
# into every later recorder call in the suite.
export STUB_CHECKS_FAIL=1
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425010
unset STUB_CHECKS_FAIL
S21_REC10="$(cat "$S21_FILE-425010.json" 2>/dev/null || echo)"
assert_contains "$S21_REC10" '"check_surface":"unknown"' "21.10 an UNREADABLE surface records 'unknown' (never 'green' — absence is not evidence)"
if grep -q '"check_surface":"green"' <<<"$S21_REC10"; then
    bad "21.10 a failed read was recorded as GREEN"
else
    ok "21.10 …and NOT 'green'"
fi
# 21.17 A SURFACE WHOSE ROWS ARE ALL EXCLUDED IS `empty`, NOT `green` — review of `554d272`, P2.
# The early guard caught only an EMPTY RESPONSE, so a head whose only run is the excluded
# `ai-review-gate` fell through to `green`: the record asserted `check_surface:green` about a
# surface whose only observed check is RED (contradicting the scan's own contract, line 2470, and
# the mint-path comment), and `--check-carry` printed NO not-green line where the design promises
# one. "Nothing observable" must never be worded as "everything observed passed".
s21_rows "$S21_HEAD" 'ai-review-gate|ai-review-gate|99|completed|failure'
s21_rows "$S21_BASE" "$S21_GREEN" "$S21_GREEN2"
s21_rec 425018 "$S21_HEAD"
s21_run 425018
assert_eq "$CC_RC" "0" "21.17 an all-excluded surface keeps the normal answer (the exclusion is a recorded decision, not a refusal)"
assert_contains "$(cat "$T/s21-err" 2>/dev/null)" "NO readable check run" "21.17 …and is LOUD that nothing observable is not green (it used to be silently 'green')"
export STUB_CHECKS_ROWS_DIR="$S21_ROWS"
rm -f "$S21_FILE-425020.json"   # the MINT under test must create it: a pre-existing record
# with the same deterministic identity makes the mint a #1709 rec 7 NO-OP, so the file would
# keep the shape below and the assertion would measure nothing.
EV_REF="comment:7391001" run_record_verdict clean "$S21_REPO" 425020
S21_REC20="$(cat "$S21_FILE-425020.json" 2>/dev/null || echo)"
if [ ! -s "$S21_FILE-425020.json" ]; then
    bad "21.17 fixture: the mint wrote NO record (rc=$RECORD_RC, err=$(printf '%s' "$RECORD_ERR" | command tail -3))"
fi
assert_contains "$S21_REC20" '"check_surface":"unknown"' "21.17 an all-excluded surface records 'unknown', never 'green'"
if grep -q '"check_surface":"green"' <<<"$S21_REC20"; then
    bad "21.17 a surface with NOTHING observable was recorded as GREEN"
else
    ok "21.17 …and NOT 'green'"
fi
# (a) MUTATION PIN — revert the `nseen == 0` branch and the SAME fixture records `green`.
S21_MUT18="$S21_MUTDIR/record-review-s21-excludedgreen.sh"
cp "$RECORD" "$S21_MUT18"
if grep -qF 'else if (nseen == 0) print "empty"' "$S21_MUT18"; then
    sed -i.bak 's#else if (nseen == 0) print "empty"#else if (nseen == 0) print "green"#' "$S21_MUT18"
    rm -f "$S21_MUT18.bak"
    if cmp -s "$RECORD" "$S21_MUT18"; then
        bad "21.17 mutation: the sed did not apply — re-anchor it rather than dropping the pin"
    else
        printf '{"pr":%s,"head_sha":"%s","diff_sha256":"%s","verdict":"clean","mint":"fresh","repo":"%s","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
            "425021" "$S21_HEAD" "$S21_SHA" "$S21_REPO" > "$S21_FILE-425021.json"
        S21_RECORD_SAVE="$RECORD"
        RECORD="$S21_MUT18"
        EV_REF="comment:7391001" run_record "$S21_REPO" 425021
        RECORD="$S21_RECORD_SAVE"
        S21_REC21="$(cat "$S21_FILE-425021.json" 2>/dev/null || echo)"
        # ⛔ NO PIPE (#841/#864) — here-string, the transform the exceptions file records.
        if grep -q '"check_surface":"green"' <<<"$S21_REC21"; then
            ok "21.17 MUTATION PIN: with the 'nothing observable' branch reverted the record says check_surface=green over the SAME excluded-only surface — the branch is load-bearing"
        else
            bad "21.17 mutation NOT caught (record: $S21_REC21) — 21.17 would pass on a reader that calls an unobservable surface green"
        fi
    fi
else
    bad "21.17 the 'nothing observable is empty' branch is gone — re-anchor the pin"
fi

# 21.18 AN AMBIENT `RECORD_REVIEW_RED_EXCLUDE` CANNOT HIDE A RED — review of `988d0968`, and it is
# category A, not a nit: "disable a gate by ambient env" is a BYPASS. The exclusion used to be
# `${RECORD_REVIEW_RED_EXCLUDE-…}`, so any caller could REPLACE it — including with the name of the
# very job that is failing — and `--check-carry` then read the surface GREEN and answered `head` /
# exit 0 (a merge licence), which check (c) passes on. The exclusion itself is a recorded decision
# (#1590) and is unchanged; only the silent per-invocation override is gone.
s21_rows "$S21_HEAD" "$S21_GREEN" 'CI|verify|12|completed|failure'   # only `verify` is RED on the head
s21_rows "$S21_BASE" "$S21_GREEN" "$S21_GREEN2"
s21_rec 425022 "$S21_HEAD"
CC_RC=0
CC_OUT="$(HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
    RECORD_REVIEW_RED_EXCLUDE="verify" \
    STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 \
    STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
    STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
    bash "$RECORD" --check-carry 425022 "$S21_REPO" 2>"$T/s21-err")" || CC_RC=$?
assert_eq "$CC_RC" "7" "21.18 an ambient RED_EXCLUDE naming the failing job still answers exit 7 (a gate cannot be disabled from the environment)"
assert_eq "${CC_OUT%%"$S21_TAB"*}" "red-surface" "21.18 …with its own token, never 'head'"
# (a) MUTATION PIN — restore the `${VAR-default}` override and the SAME invocation answers `head`/0.
S21_MUT19="$S21_MUTDIR/record-review-s21-envoverride.sh"
cp "$RECORD" "$S21_MUT19"
if grep -qxF 'RECORD_REVIEW_RED_EXCLUDE="ai-review-gate ai-review-gate-tests"' "$S21_MUT19"; then
    sed -i.bak 's#^RECORD_REVIEW_RED_EXCLUDE="ai-review-gate ai-review-gate-tests"$#RECORD_REVIEW_RED_EXCLUDE="${RECORD_REVIEW_RED_EXCLUDE-ai-review-gate ai-review-gate-tests}"#' "$S21_MUT19"
    rm -f "$S21_MUT19.bak"
    if cmp -s "$RECORD" "$S21_MUT19"; then
        bad "21.18 mutation: the sed did not apply — re-anchor it rather than dropping the pin"
    else
        S21_RC19=0
        HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" GH_REPO="" \
            RECORD_REVIEW_RED_EXCLUDE="verify" \
            STUB_DIFF_FILE="$S21_DIFF" STUB_DIFF_FAIL=0 \
            STUB_HEAD_SHA="$S21_HEAD" STUB_BASE_SHA="$S21_BASE" \
            STUB_CHECKS_ROWS_DIR="$S21_ROWS" \
            bash "$S21_MUT19" --check-carry 425022 "$S21_REPO" >/dev/null 2>&1 || S21_RC19=$?
        if [ "$S21_RC19" -eq 0 ]; then
            ok "21.18 MUTATION PIN: with the ambient override restored the same invocation answers exit 0 over the SAME red head — the override was a bypass, not a convenience"
        else
            bad "21.18 mutation NOT caught (rc=$S21_RC19, wanted 0) — 21.18 would pass without the pin"
        fi
    fi
else
    bad "21.18 the constant exclusion assignment is gone — re-anchor the pin"
fi
unset STUB_CHECKS_ROWS_DIR
rm -rf "$S21_ROWS"

echo ""
# ═════════════════════════════════════════════════════════════════════════
# 20. DELTA EVIDENCE: --evidence delta:<A>..<B>[+<artifact>]
#
# A delta attestation claims "at head B a reviewer reviewed exactly the commits
# A..B and nothing else changed in the authored diff". Every vector below FAILS
# without its guard, and the mutation matrix at the end proves that by breaking
# each guard in a scratch copy of the recorder and naming the vector that goes
# RED. A delta that can be minted for ANY two shas is worse than no delta: it is
# a signature with no content, so the refusal vectors are the deliverable.
# ═════════════════════════════════════════════════════════════════════════
echo "── 20. delta evidence: a RANGE-scoped verdict ─────────────────"
ORIG_PWD="$(pwd)"   # §20 cds into its fixture repo; a later §21 must not inherit that cwd

DG="$T/dgit"; mkdir -p "$DG"; cd "$DG" || bad "20 setup: cannot enter fixture repo"
git init -q . >/dev/null 2>&1; git config user.email t@t; git config user.name t
printf 'base\n' > f.txt; git add -A
GIT_COMMITTER_DATE='2024-01-01T00:00:00Z' GIT_AUTHOR_DATE='2024-01-01T00:00:00Z' git commit -qm base
DG_BASE="$(git rev-parse HEAD)"
DG_MAIN="$(git rev-parse --abbrev-ref HEAD)"   # whatever the init default is (main or master)
git checkout -qb pr
printf 'lane\n' > lane.txt; git add -A
GIT_COMMITTER_DATE='2025-06-01T00:00:00Z' GIT_AUTHOR_DATE='2025-06-01T00:00:00Z' git commit -qm 'lane work'
DG_A1="$(git rev-parse HEAD)"          # the REVIEWED head (lane-authored, 2025-06-01)
git checkout -q "$DG_MAIN"
printf 'mainland\n' > m.txt; git add -A
GIT_COMMITTER_DATE='2025-07-01T00:00:00Z' GIT_AUTHOR_DATE='2025-07-01T00:00:00Z' git commit -qm 'main work'
DG_M1="$(git rev-parse HEAD)"          # the BASE tip after main moved
git checkout -q pr
GIT_COMMITTER_DATE='2024-02-01T00:00:00Z' GIT_AUTHOR_DATE='2024-02-01T00:00:00Z' \
  git merge -q --no-ff "$DG_MAIN" -m 'forward-merge base into pr' >/dev/null 2>&1
DG_HEAD="$(git rev-parse HEAD)"        # B: a merge whose base side carries DG_M1
# per-sha commit dates: the delta's covering-verdict ANCHOR is the newest AUTHORED
# commit (2025-06-01), while the head merge commit is dated EARLIER (2024-02-01).
# Only a per-sha map can tell those two anchors apart.
mkdir -p "$T/dates"
printf '%s\n' '2024-01-01T00:00:00Z' > "$T/dates/$DG_BASE"
printf '%s\n' '2025-06-01T00:00:00Z' > "$T/dates/$DG_A1"
printf '%s\n' '2025-07-01T00:00:00Z' > "$T/dates/$DG_M1"
printf '%s\n' '2024-02-01T00:00:00Z' > "$T/dates/$DG_HEAD"
[ -n "$DG_BASE$DG_A1$DG_M1$DG_HEAD" ] || bad "20 setup: fixture shas are empty"

# The delta needs a checkout of the repo whose origin IS the repo being recorded.
git remote add origin 'git@github.com:daniel-ospina/agent-infra.git' 2>/dev/null || true

# A runner that can mint at an ARBITRARY sha (run_record_ev is pinned to $SHA,
# and a delta's B must be a REAL commit, so the fake 40×a head cannot serve here).
run_record_delta() { # <pr> <sha> <ref> [VAR=VAL…] → $RECORD_RC $RECORD_ERR
    local pr="$1" sha="$2" ref="$3"; shift 3
    local rcfile="$T/drc" errfile="$T/derr" kv
    rm -f "$errfile"; : > "$LOG"
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        export STUB_HEAD_SHA="$sha" DELTA_GIT_DIR="$DG"
        export STUB_BASE_PAIR=1 STUB_BASE_SHA="$DG_M1" STUB_BASE_REF=main
        # (10a) An authored delta needs the artifact to NAME the range, so the default
        # body states it exactly as a reviewer would quote it.
        export STUB_EVIDENCE_BODY="reviewed ${ref%%+*}; no issues found."
        export STUB_COMMIT_DATES_DIR="$T/dates" STUB_COMMIT_DATE="2030-01-01T00:00:00Z"
        for kv in "$@"; do export "$kv"; done
        # ⛔ AND IT MUST CARRY THE #3442 BLOCK. `verify_review_evidence` now refuses a FRESH
        # `clean` verdict over an artifact with no `## MUTATION ATTRIBUTION` table, and every
        # vector in this section mints one — so without the block EVERY arm below refused at 3
        # for a reason unrelated to what it pins (the unrelated-row trap #3442's own fixture
        # note names). Applied AFTER the caller's overrides so a vector's own body is
        # byte-unchanged up to the blank line: the delta arms below SCAN that body for stated
        # ranges, and the block must not be the thing they compare. A vector that deliberately
        # omits the block opts out with DELTA_NO_VACUITY_BLOCK=1 rather than relying on order.
        if [ "${DELTA_NO_VACUITY_BLOCK:-0}" != 1 ]; then
            case "$STUB_EVIDENCE_BODY" in
                *"MUTATION ATTRIBUTION"*) : ;;
                *) STUB_EVIDENCE_BODY="$STUB_EVIDENCE_BODY

$VACUITY_BLOCK"; export STUB_EVIDENCE_BODY ;;
            esac
        fi
        rc=0
        # shellcheck disable=SC2086  # EXTRA_ARGS is intentionally word-split (one flag)
        bash "$RECORD" "$pr" "$sha" clean "daniel-ospina/agent-infra" --evidence "$ref" ${EXTRA_ARGS:-} 2>"$errfile" || rc=$?
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# ── 20a — the ACCEPTANCE half: a base-borne merge-only range records clean ──
# A1..HEAD contains exactly one non-merge commit (DG_M1, what main landed) and it
# is reachable from the PR's base — the LANE authored nothing. Without the
# base-aware classification this vector is REFUSED as "authored", which is the
# 8-re-reviews-for-zero-authored-lines cost agent-infra#3245 measured.
# A merge-only delta EXTENDS an attestation, so the lane's earlier record at A1 is
# planted first (review of this change reproduced the zero-evidence mint that
# skipped exactly this premise: with no record at A, `clean` was minted for a head
# whose authored content nobody had reviewed).
EP=425100; rm -f "$(Q2 $EP)"
printf '%s\n' '2025-06-01T00:00:00Z' > "$T/dates/$DG_A1"
run_record_delta $EP "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42510001" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" STUB_EVIDENCE_BODY="reviewed $DG_A1; no issues found."
assert_eq "$RECORD_RC" "0" "20a a base-borne merge-only delta with a real cover records clean (rc 0)"
R20="$(cat "$(Q2 $EP)" 2>/dev/null || true)"
assert_contains "$R20" '"delta_kind":"merge-only"' "20a the record says the range was merge-only"
assert_contains "$R20" "\"delta_base\":\"$DG_M1\"" "20a the record stores the BASE it was classified against (re-derivable)"
assert_contains "$R20" "\"delta_range\":\"$DG_A1..$DG_HEAD\"" "20a the record stores the range it claims"
assert_contains "$R20" '"delta_digest":"' "20a the record stores a digest, so the claim is checkable later"
assert_contains "$R20" '"mint":"fresh"' "20a a delta is a FRESH mint (never a carry)"
assert_contains "$R20" "\"head_sha\":\"$DG_HEAD\"" "20a the record is still head-bound to B"
DIG20="$(sed -n 's/.*"delta_digest":"\([0-9a-f]*\)".*/\1/p' "$(Q2 $EP)" 2>/dev/null | head -1 || true)"
if [[ "$DIG20" =~ ^[0-9a-f]{64}$ ]]; then ok "20a the digest is a full 64-hex sha256"; else bad "20a digest is not 64-hex (got '$DIG20')"; fi
# The digest must be RE-DERIVABLE from the two shas — that is the whole claim.
RECOMP="$(git -C "$DG" -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
   -c diff.suppressBlankEmpty=false diff --no-color --no-ext-diff --no-textconv --full-index \
   --src-prefix=a/ --dst-prefix=b/ --unified=3 --diff-algorithm=myers --find-renames \
   "$DG_A1" "$DG_HEAD" 2>/dev/null | python3 "$SCRIPT_DIR/lib/diff-normalize.py" 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')"
assert_eq "$RECOMP" "$DIG20" "20a an independent re-derivation of diff A..B matches the recorded digest"

# ── 20b — A NOT AN ANCESTOR OF B (a rebase-shaped range) is refused ───────
# DG_HEAD is NOT an ancestor of DG_A1: "the commits in between" has no meaning,
# and a delta must never be mintable for two arbitrary shas.
EB=425101; rm -f "$(Q2 $EB)"
run_record_delta $EB "$DG_A1" "delta:$DG_HEAD..$DG_A1"
assert_eq "$RECORD_RC" "3" "20b a non-ancestor pair is refused (rc 3)"
assert_contains "$RECORD_ERR" "NOT an ancestor" "20b the refusal says WHY (not a chain)"
[ ! -f "$(Q2 $EB)" ] && ok "20b no record written" || bad "20b a record was written for a non-chain range"

# ── 20c — B MUST BE LIVE HEAD: two arms, both refused ─────
# (c1) the range's upper bound is not the head being recorded.
EC=425102; rm -f "$(Q2 $EC)"
run_record_delta $EC "$DG_A1" "delta:$DG_A1..$DG_HEAD"
assert_eq "$RECORD_RC" "3" "20c1 B != the recorded head is refused (rc 3)"
assert_contains "$RECORD_ERR" "must BE the head it attests" "20c1 the refusal says the range must end at the attested head"
[ ! -f "$(Q2 $EC)" ] && ok "20c1 no record written" || bad "20c1 a record was written for a misbounded range"
# (c2) the RECORDED head is stale: the delta must not become a carry.
# A new LANE-authored commit lands after the reviewed merge, so every carry arm
# must fail on its own terms and the stale-sha guard must refuse.
git checkout -q pr >/dev/null 2>&1
printf 'after-review\n' > after.txt; git add -A
GIT_COMMITTER_DATE='2025-09-01T00:00:00Z' GIT_AUTHOR_DATE='2025-09-01T00:00:00Z' git commit -qm 'lane fix after review'
DG_NEW="$(git rev-parse HEAD)"
printf '%s\n' '2025-09-01T00:00:00Z' > "$T/dates/$DG_NEW"
EC2=425103; rm -f "$(Q2 $EC2)"
run_record_delta $EC2 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" STUB_HEAD_SHA="$DG_NEW"
assert_eq "$RECORD_RC" "3" "20c2 a delta whose B is no longer the LIVE head is refused (rc 3)"
assert_contains "$RECORD_ERR" "stale-sha guard" "20c2 the stale-sha guard is what refused it (the delta did not buy a carry)"
[ ! -f "$(Q2 $EC2)" ] && ok "20c2 no record written" || bad "20c2 a record was written for a stale delta"

# ── 20d — an AUTHORED range needs a covering verdict ─────
# DG_BASE..DG_HEAD contains DG_A1 (lane-authored, not reachable from the base).
ED1=425104; rm -f "$(Q2 $ED1)"
run_record_delta $ED1 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD"
assert_eq "$RECORD_RC" "3" "20d1 an authored range with NO covering verdict is refused (rc 3)"
assert_contains "$RECORD_ERR" "authored content" "20d1 the refusal names the authored content"
assert_contains "$RECORD_ERR" "+comment:" "20d1 the refusal names the composed remedy"
[ ! -f "$(Q2 $ED1)" ] && ok "20d1 no record written" || bad "20d1 a record was written for an uncovered authored range"
# 20d2 the composed form is ACCEPTED when the verdict postdates the range's
#       newest authored commit (artifact 2026-01-02 ≥ 2025-06-01).
ED2=425105; rm -f "$(Q2 $ED2)"
run_record_delta $ED2 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42510501"
assert_eq "$RECORD_RC" "0" "20d2 authored range + a covering verdict records clean (rc 0)"
R20D="$(cat "$(Q2 $ED2)" 2>/dev/null || true)"
assert_contains "$R20D" '"delta_kind":"authored"' "20d2 the record says the range was authored"
assert_contains "$R20D" "+comment:42510501" "20d2 the record keeps the composed ref (which verdict covers the range)"
# 20d3 the covering verdict must POSTDATE the newest AUTHORED commit — not merely
#       the head merge commit (dated 2024-02-01, EARLIER than the authored work).
ED3=425106; rm -f "$(Q2 $ED3)"
run_record_delta $ED3 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42510601" \
    STUB_EVIDENCE_AT="2025-01-01T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20d3 a verdict predating the newest AUTHORED commit is refused (rc 3)"
[ ! -f "$(Q2 $ED3)" ] && ok "20d3 no record written" || bad "20d3 a record was written for a verdict that never saw the authored work"
# 20d4 an UNREADABLE base refuses rather than classifying itself.
ED4=425107; rm -f "$(Q2 $ED4)"
run_record_delta $ED4 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" STUB_BASE_PAIR_FAIL=1
assert_eq "$RECORD_RC" "3" "20d4 an unreadable BASE refuses (rc 3, no self-classification)"
assert_contains "$RECORD_ERR" "could not read the PR's BASE" "20d4 the refusal names the missing input"

# ── 20e — BACKWARD COMPATIBILITY: every pre-existing shape still works ──
# ⛔ EACH VECTOR NAMES ITS OWN (CLEAN) BODY. The shared default stub body is a
# `## Review — NOT CLEAN` header (#3400's polarity arms consume it), so a vector
# that leaves STUB_EVIDENCE_BODY to the default is refused for polarity — not
# for the shape it exists to pin, which made 20e red for a reason it does not
# measure. The clean shapes are what backward compat means here.
EE=425108; rm -f "$(Q2 $EE)"
EV_REF="comment:42510801" run_record_ev $EE STUB_EVIDENCE_BODY="**Outcome: CLEAN — verified, no issues.**

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "20e comment:<id> evidence still records clean (rc 0)"
assert_contains "$(cat "$(Q2 $EE)" 2>/dev/null || true)" '"evidence":"comment:42510801"' "20e the record still names the comment"
if grep -qF 'delta_' "$(Q2 $EE)" 2>/dev/null; then bad "20e a comment record grew delta fields"; else ok "20e a comment record carries NO delta fields (shape unchanged)"; fi
EE2=425109; rm -f "$(Q2 $EE2)"
EV_REF="review:42510901" run_record_ev $EE2 STUB_REVIEW_STATE=APPROVED STUB_EVIDENCE_BODY="**Outcome: CLEAN — verified, no issues.**

$VACUITY_BLOCK"
assert_eq "$RECORD_RC" "0" "20e review:<id> evidence still records clean (rc 0)"

# ── 20f — the OTHER refusal arms ─────
# empty range (A == B): a trivially-true delta is a signature with no content.
EF=425110; rm -f "$(Q2 $EF)"
run_record_delta $EF "$DG_HEAD" "delta:$DG_HEAD..$DG_HEAD"
assert_eq "$RECORD_RC" "3" "20f an EMPTY range (A == B) is refused"
assert_contains "$RECORD_ERR" "empty range attests nothing" "20f the refusal says why"
# an empty DIFF: a merge whose tree matches the range start attests no review.
git checkout -q pr >/dev/null 2>&1
git commit -q --allow-empty -m 'empty commit'
DG_EMPTY="$(git rev-parse HEAD)"
printf '%s\n' '2025-10-01T00:00:00Z' > "$T/dates/$DG_EMPTY"
EF2=425111; rm -f "$(Q2 $EF2)"
run_record_delta $EF2 "$DG_EMPTY" "delta:$DG_NEW..$DG_EMPTY"
assert_eq "$RECORD_RC" "3" "20f a range whose diff is EMPTY is refused"
assert_contains "$RECORD_ERR" "is EMPTY" "20f the refusal names the empty diff"
# a malformed ref: the delta shape is pinned, not a loose prefix.
EF3=425112; rm -f "$(Q2 $EF3)"
run_record_delta $EF3 "$DG_HEAD" "delta:abc..def"
assert_eq "$RECORD_RC" "3" "20f a short-sha delta ref is refused (shape pinned)"
EF4=425113; rm -f "$(Q2 $EF4)"
run_record_delta $EF4 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+nested:1"
assert_eq "$RECORD_RC" "3" "20f an unknown covering-artifact kind is refused"
# a NESTED delta cannot inherit authority. ⛔ THIS VECTOR PINS THE **SHAPE** GUARD,
# NOT ARM (2). `evidence_ref_split` pins the cover to
# `(comment|issuecomment|review|review-comment|discussion):<id>`, so a `+delta:` cover
# is refused as a MALFORMED REF before `delta_verify` is ever entered — the assertion
# below therefore passes for a reason arm (2) had no part in. 20f-b measures arm (2).
EF5=425114; rm -f "$(Q2 $EF5)"
run_record_delta $EF5 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+delta:$DG_A1..$DG_HEAD"
assert_eq "$RECORD_RC" "3" "20f a delta covering a delta is refused (by the pinned REF SHAPE)"
assert_contains "$RECORD_ERR" "accepted: comment:" "20f …and the refusal is the shape guard's own message, not arm (2)'s"
# 20f-b ARM (2) MEASURED DIRECTLY. The nested-delta arm is defence-in-depth for a
#       DIRECT caller (the function is sourceable — this suite extracts functions
#       elsewhere too), and no CLI invocation can reach it, so only a direct call
#       measures it. Without this vector the arm is a claim with no test behind it.
awk '/^delta_verify\(\) \{/,/^\}$/' "$RECORD" > "$T/dvfn.sh"
[ -s "$T/dvfn.sh" ] && ok "20f-b delta_verify extracted from the recorder" || bad "20f-b could not extract delta_verify"
dvrc=0
( . "$T/dvfn.sh"; delta_verify "$DG_BASE..$DG_HEAD+delta:$DG_A1..$DG_HEAD" "$DG_HEAD" ) \
    >"$T/dvout" 2>"$T/dverr" || dvrc=$?
assert_eq "$dvrc" "1" "20f-b arm (2) called DIRECTLY refuses a nested delta (rc 1)"
assert_contains "$(cat "$T/dverr" 2>/dev/null || true)" "is itself a delta" "20f-b …naming the arm's own reason (so the vector is not satisfied by an earlier arm)"
# 20f-c THE DELTA × CARRY-FIRED ARM. A delta ref supplied while a carry arm already
#       re-bound the verdict would be recorded by NOBODY: the record states the carry,
#       not a reviewer's range. The caller is told the delta was recorded while the
#       audit trail holds none — a silent drop, so this must REFUSE. No vector covered
#       this arm, so it is measured END TO END below: the recorder is run at a STALE
#       sha with the LIVE head at $DG_HEAD, which is what puts it on the carry path.
#       ⛔ It is asserted on the ARM'S OWN MESSAGE, not on the exit code: arm (4)
#       ("B != the head being recorded") produces a bare rc 3 in exactly this region,
#       so a code-only assertion would pass with the carry arm never entered.
# A runner that can carry: cwd must be the FIXTURE (lane_dimension_carry runs bare
# `git`, not delta_git), and the LIVE head must differ from the recorded sha.
run_record_carry_at() { # <pr> <recorded-sha> <live-sha> <ref> → $RECORD_RC $RECORD_ERR
    local pr="$1" rsha="$2" lsha="$3" ref="$4"
    local rcfile="$T/crc" errfile="$T/cerr"
    rm -f "$errfile"; : > "$LOG"
    (
        cd "$DG" || exit 9
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra"
        export STUB_HEAD_SHA="$lsha" DELTA_GIT_DIR="$DG"
        export STUB_BASE_PAIR=1 STUB_BASE_SHA="$DG_M1" STUB_BASE_REF=main
        export STUB_EVIDENCE_BODY="reviewed ${ref%%+*}; no issues found."
        export STUB_COMMIT_DATES_DIR="$T/dates" STUB_COMMIT_DATE="2030-01-01T00:00:00Z"
        export STUB_EVIDENCE_AT="2026-01-01T00:00:00Z"
        rc=0
        if [ -n "$ref" ]; then
            bash "$RECORD" "$pr" "$rsha" clean "daniel-ospina/agent-infra" --evidence "$ref" 2>"$errfile" || rc=$?
        else
            bash "$RECORD" "$pr" "$rsha" clean "daniel-ospina/agent-infra" 2>"$errfile" || rc=$?
        fi
        printf '%s' "$rc" > "$rcfile"
    ) 2>/dev/null
    RECORD_RC="$(cat "$rcfile" 2>/dev/null || echo 99)"
    RECORD_ERR="$(cat "$errfile" 2>/dev/null || true)"
}
EH20D=425170; rm -f "$(Q2 $EH20D)"
printf '{"pr":%d,"head_sha":"%s","evidence":"comment:42517001","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-06-02T00:00:00Z"}\n' \
    "$EH20D" "$DG_A1" > "$(Q2 $EH20D)"
run_record_carry_at $EH20D "$DG_A1" "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42517002"
assert_eq "$RECORD_RC" "3" "20f-c a delta supplied while a carry arm re-bound the verdict is refused (rc 3)"
assert_contains "$RECORD_ERR" "already re-bound" "20f-c …by the carry-vs-delta arm, so the delta cannot be silently dropped"
# CONTROL: the same invocation WITHOUT the delta ref must actually CARRY, or 20f-c
# above would be satisfied by a carry path that never fires at all.
EH20E=425171; rm -f "$(Q2 $EH20E)"
printf '{"pr":%d,"head_sha":"%s","evidence":"comment:42517101","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-06-02T00:00:00Z"}\n' \
    "$EH20E" "$DG_A1" > "$(Q2 $EH20E)"
run_record_carry_at $EH20E "$DG_A1" "$DG_HEAD" "comment:42517102"
assert_eq "$RECORD_RC" "0" "20f-c control: the SAME invocation without a delta ref carries (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
assert_contains "$(cat "$(Q2 $EH20E)" 2>/dev/null || true)" '"mint":"carried"' "20f-c control: …and records mint=carried, so the carry arm really fired"

# 20f-d A CARRY THAT INHERITS A `delta:` CLAIM MUST CARRY THE CLAIM'S FIELDS.
#       A carry copies the predecessor's `evidence` verbatim, so without this the
#       carried record asserts a RANGE while `delta_range`/`delta_base`/`delta_kind`/
#       `delta_digest` are absent — the claim the feature exists to make checkable,
#       stated with nothing behind it. Composition between this feature and the
#       carry-provenance arm (#10177); neither side could see it alone.
DV_DIGEST="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
EH21=425172; rm -f "$(Q2 $EH21)"
printf '{"pr":%d,"head_sha":"%s","evidence":"delta:%s..%s+comment:42517201","delta_range":"%s..%s","delta_base":"%s","delta_kind":"lane","delta_digest":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-06-02T00:00:00Z"}\n' \
    "$EH21" "$DG_A1" "$DG_BASE" "$DG_A1" "$DG_BASE" "$DG_A1" "$DG_M1" "$DV_DIGEST" > "$(Q2 $EH21)"
run_record_carry_at $EH21 "$DG_A1" "$DG_HEAD" ""
assert_eq "$RECORD_RC" "0" "20f-d a carry inheriting a delta claim records (rc 0) [err: $(printf '%s' "$RECORD_ERR" | tr '\n' ' ')]"
R21="$(cat "$(Q2 $EH21)" 2>/dev/null || true)"
assert_contains "$R21" '"mint":"carried"' "20f-d …as a carry"
assert_contains "$R21" "\"delta_range\":\"$DG_BASE..$DG_A1\"" "20f-d …keeping the REVIEWED range, not the range up to the carry head"
assert_contains "$R21" "\"delta_base\":\"$DG_M1\"" "20f-d …and the base it was classified against (re-derivable)"
assert_contains "$R21" '"delta_kind":"lane"' "20f-d …and its classification"
assert_contains "$R21" "\"delta_digest\":\"$DV_DIGEST\"" "20f-d …and the digest, so the inherited claim stays checkable"
assert_contains "$R21" '"evidence":"delta:' "20f-d …while the evidence it inherits is the delta claim it substantiates"
# REFUSAL DIRECTION: a predecessor that names a delta but carries none of its fields
# must be REFUSED, never transcribed — otherwise the record would assert a range with
# nothing behind it, which is the shape this guard exists to stop.
EH22=425173; rm -f "$(Q2 $EH22)"
printf '{"pr":%d,"head_sha":"%s","evidence":"delta:%s..%s+comment:42517301","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-06-02T00:00:00Z"}\n' \
    "$EH22" "$DG_A1" "$DG_BASE" "$DG_A1" > "$(Q2 $EH22)"
run_record_carry_at $EH22 "$DG_A1" "$DG_HEAD" ""
assert_eq "$RECORD_RC" "3" "20f-d a carry inheriting a delta claim with NO delta fields is refused (rc 3)"
assert_contains "$RECORD_ERR" "inherits a delta claim" "20f-d …naming the unsubstantiated claim"
assert_not_contains "$(cat "$(Q2 $EH22)" 2>/dev/null || true)" '"mint":"carried"' "20f-d …and nothing was recorded over the predecessor"
# a delta with a NON-CLEAN verdict is an argument-level contradiction (the
# clean-micro/clean-low arms never read evidence, so it would be dropped silently).
EF6=425115; rm -f "$(Q2 $EF6)"
(
    export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" DELTA_GIT_DIR="$DG"
    export STUB_EVIDENCE_PR=425115 STUB_EVIDENCE_REPO="daniel-ospina/agent-infra" STUB_HEAD_SHA="$DG_HEAD"
    rc=0
    bash "$RECORD" 425115 "$DG_HEAD" clean-micro "daniel-ospina/agent-infra" \
        --evidence "delta:$DG_A1..$DG_HEAD" >/dev/null 2>"$T/derr6" || rc=$?
    printf '%s' "$rc" > "$T/drc6"
) 2>/dev/null
assert_eq "$(cat "$T/drc6" 2>/dev/null || echo 99)" "2" "20f delta evidence with a non-clean verdict exits 2"

# ── 20h — the arms review of this change reproduced bypasses through ─────
# 20h1 MERGE-ONLY WITH NO ATTESTED A: the zero-evidence mint. Same shape as 20a
#      but with no prior record at A and no cover → refused.
EH1=425130; rm -f "$(Q2 $EH1)"
run_record_delta $EH1 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD"
assert_eq "$RECORD_RC" "3" "20h1 a merge-only delta whose A is NOT attested is refused (rc 3)"
assert_contains "$RECORD_ERR" "EXTENDS an attestation and can never create one" "20h1 the refusal names the missing premise (extends, never creates)"
[ ! -f "$(Q2 $EH1)" ] && ok "20h1 no record written (zero-evidence mint closed)" || bad "20h1 a zero-evidence clean was minted"

# 20h2 AN EVIL MERGE: a conflict resolution living ONLY in the merge commit. The
#      `--no-merges` walk is blind to it, so without clause (D)'s tree check the
#      range classifies merge-only and mints clean over lines no reviewer saw.
git checkout -q -b evil "$DG_A1" >/dev/null 2>&1
printf 'lane side\n' > f.txt; git add -A
git commit -qm 'lane edits f'
DG_EV_L="$(git rev-parse HEAD)"
git checkout -q "$DG_MAIN" >/dev/null 2>&1
printf 'base side\n' > f.txt; git add -A
GIT_COMMITTER_DATE='2025-07-01T00:00:00Z' GIT_AUTHOR_DATE='2025-07-01T00:00:00Z' git commit -qm 'base edits f'
DG_EV_B="$(git rev-parse HEAD)"
printf '%s\n' '2025-07-01T00:00:00Z' > "$T/dates/$DG_EV_B"
git checkout -q evil >/dev/null 2>&1
git -c core.editor=true merge --no-ff "$DG_EV_B" -m 'merge base (CONFLICT)' >/dev/null 2>&1 || true
printf 'EVIL RESOLUTION nobody reviewed\n' > f.txt; git add -A
git -c core.editor=true commit -qm 'resolve conflict by hand' >/dev/null 2>&1 || true
DG_EV_HEAD="$(git rev-parse HEAD)"
printf '%s\n' '2025-11-01T00:00:00Z' > "$T/dates/$DG_EV_HEAD"
printf '%s\n' '2025-10-01T00:00:00Z' > "$T/dates/$DG_EV_L"
if [ "$(git -C "$DG" rev-list --merges "$DG_EV_L..$DG_EV_HEAD" --not "$DG_M1" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "20h2 fixture: the range's only new commit is the merge (the evil-merge shape)"
else
    bad "20h2 fixture: the range does not hold exactly one merge — the vector would not test the arm"
fi
EH2=425131; rm -f "$(Q2 $EH2)"
printf '{"pr":%d,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-10-02T00:00:00Z"}\n' \
  "$EH2" "$DG_EV_L" > "$(Q2 $EH2)"
run_record_delta $EH2 "$DG_EV_HEAD" "delta:$DG_EV_L..$DG_EV_HEAD"
assert_eq "$RECORD_RC" "3" "20h2 an EVIL MERGE (hand-resolved conflict) is refused (rc 3)"
for _m2 in "NOT a clean merge of its parents" "does NOT merge cleanly"; do
    case "$RECORD_ERR" in *"$_m2"*) ok "20h2 the refusal names the conflict resolution"; _named2=1; break ;; esac
done
# ⛔ A LOOP WITH NO FAILURE BRANCH IS AN ASSERTION THAT STOPS EXISTING WHEN THE WORDING MOVES:
#    if neither phrasing appears, neither `ok` nor `bad` used to fire and the arm silently
#    vanished (agent-infra#3475). The assertion now has a red half.
[ "${_named2:-0}" = 1 ] || bad "20h2 the refusal does NOT name the conflict resolution (err='$RECORD_ERR')"
assert_contains "$RECORD_ERR" "authored content" "20h2 the evil merge is classified AUTHORED, not merge-only"
# ⛔ 20h2b — THE MERGE-ONLY AUTHORED SENTENCE. An EVIL MERGE whose range holds NO non-merge
#    commit is `authored` with `n_authored = 0` — the shape whose diagnostic used to read
#    "contains authored content (0 commit(s))", contradicting itself on the one bypass this
#    feature exists to close. 20h2's own range carries one non-merge commit, so it takes the
#    COUNT form and the merge sentence was pinned by NOTHING (measured: inverting its condition
#    left the suite green). Here `A` is the merge's FIRST PARENT, so `--no-merges A..B` is empty.
DG_EV_P1="$(git -C "$DG" rev-parse "$DG_EV_HEAD^1")"
DG_EV_P2="$(git -C "$DG" rev-parse "$DG_EV_HEAD^2")"
printf '%s\n' '2025-10-01T00:00:00Z' > "$T/dates/$DG_EV_P1"
EH2B=4251315; rm -f "$(Q2 $EH2B)"
# ⛔ THE BASE MUST BE THE MERGE'S SECOND PARENT, not the default fixture base. Otherwise the
#    second branch's own commit is not reachable from `--not base`, it enters the walk as an
#    authored commit, and the range takes the COUNT form — the very branch this vector exists to
#    reach. With base = p2 the real-world shape is modelled exactly: the lane merged the base tip
#    (p2) into its branch and hand-resolved a conflict, so `--no-merges A..B --not base` is EMPTY
#    and the ONLY authored thing in the range is the merge's conflict resolution.
run_record_delta $EH2B "$DG_EV_HEAD" "delta:$DG_EV_P1..$DG_EV_HEAD" STUB_BASE_SHA="$DG_EV_P2"
assert_eq "$RECORD_RC" "3" "20h2b a range that is ONLY an evil merge, with no cover, is refused (rc 3)"
assert_contains "$RECORD_ERR" "holds authored content in a MERGE" "20h2b the refusal names the MERGE as the authored content — \`n_authored\` is legitimately 0 here"
assert_not_contains "$RECORD_ERR" "(0 commit(s))" "20h2b the refusal does NOT print the self-contradicting (0 commit(s)) count"
# ⛔ ASSERT THE HEAD, NOT THE FILE: this vector plants a prior record at A (that is
# what makes the merge-only arm reachable at all), so "no file" would be false even
# on a correct refusal.
assert_contains "$(cat "$(Q2 $EH2)" 2>/dev/null || true)" "\"head_sha\":\"$DG_EV_L\"" "20h2 the planted record was NOT overwritten (no clean at the evil head)"

# 20h3 CLAUSE (E): a delta may not put a signed clean on a MEASURABLY RED head.
EH3=425132; rm -f "$(Q2 $EH3)"
printf '{"pr":%d,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-06-02T00:00:00Z"}\n' \
  "$EH3" "$DG_A1" > "$(Q2 $EH3)"
RED_ROWS='ci|docs|1|completed|failure'
run_record_delta $EH3 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" STUB_CHECKS_ROWS="$RED_ROWS"
assert_eq "$RECORD_RC" "3" "20h3 a measurably RED target head is refused (clause E, rc 3)"
assert_contains "$RECORD_ERR" "MEASURABLY RED" "20h3 the refusal names the red head"
assert_contains "$(cat "$(Q2 $EH3)" 2>/dev/null || true)" "\"head_sha\":\"$DG_A1\"" "20h3 the planted record was NOT re-bound (no signed clean on a red head)"

# 20h4 THE CHECKOUT BINDING: a delta read out of ANOTHER repo's objects would be a
# false claim, so the origin must match — and a directory that is not a checkout
# at all must refuse rather than fall through.
EH4=425133; rm -f "$(Q2 $EH4)"
DG_FOREIGN="$T/foreign"; mkdir -p "$DG_FOREIGN"
git -C "$DG_FOREIGN" init -q . 2>/dev/null || true
git -C "$DG_FOREIGN" remote add origin 'git@github.com:daniel-ospina/tortoise.git' 2>/dev/null || true
run_record_delta $EH4 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" DELTA_GIT_DIR="$DG_FOREIGN" STUB_CHECKS_ROWS=
assert_eq "$RECORD_RC" "3" "20h4 a checkout of a DIFFERENT repo is refused (rc 3)"
assert_contains "$RECORD_ERR" "cannot read the range from a checkout of" "20h4 the refusal names the checkout binding"
EH5=425134; rm -f "$(Q2 $EH5)"
run_record_delta $EH5 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" DELTA_GIT_DIR="$T/not-a-repo"
assert_eq "$RECORD_RC" "3" "20h4 a directory that is not a checkout is refused (rc 3)"

# 20h5 A COVER DATED BETWEEN the authored work and an EVIL MERGE must REFUSE: the
#      anchor is the newest commit the verdict had to postdate, and a hand-resolved
#      merge is authored content even though `--no-merges` cannot see it.
git checkout -q evil >/dev/null 2>&1
git checkout -q -b evil2 "$DG_EV_L" >/dev/null 2>&1
printf 'lane 2\n' > l2.txt; git add -A
GIT_COMMITTER_DATE='2025-12-01T00:00:00Z' GIT_AUTHOR_DATE='2025-12-01T00:00:00Z' git commit -qm 'more lane work'
DG_L2="$(git rev-parse HEAD)"
printf '%s\n' '2025-12-01T00:00:00Z' > "$T/dates/$DG_L2"
git -c core.editor=true merge --no-ff "$DG_EV_B" -m 'merge base again' >/dev/null 2>&1 || true
printf 'EVIL RESOLUTION 2\n' > f.txt; git add -A
GIT_COMMITTER_DATE='2026-02-01T00:00:00Z' GIT_AUTHOR_DATE='2026-02-01T00:00:00Z' \
  git -c core.editor=true commit -qm 'resolve again' >/dev/null 2>&1 || true
DG_EV2_HEAD="$(git rev-parse HEAD)"
printf '%s\n' '2026-02-01T00:00:00Z' > "$T/dates/$DG_EV2_HEAD"
EH6=425135; rm -f "$(Q2 $EH6)"
run_record_delta $EH6 "$DG_EV2_HEAD" "delta:$DG_EV_L..$DG_EV2_HEAD+comment:42513501" \
    STUB_EVIDENCE_AT="2026-01-01T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20h5 a cover predating an EVIL MERGE is refused (the merge is in the anchor set)"
assert_eq "$(cat "$(Q2 $EH6)" 2>/dev/null | wc -c | tr -d ' ')" "0" "20h5 no record written"
# and the SAME range with a cover that postdates the merge IS accepted — the arm
# refuses the ordering, not the shape.
EH7=425136; rm -f "$(Q2 $EH7)"
run_record_delta $EH7 "$DG_EV2_HEAD" "delta:$DG_EV_L..$DG_EV2_HEAD+comment:42513601" \
    STUB_EVIDENCE_AT="2026-03-01T00:00:00Z"
assert_eq "$RECORD_RC" "0" "20h5 a cover that postdates the evil merge still records (arm is an ordering test)"

# 20h6 A MERGE-ONLY DELTA WITH NO COVER IS REFUSED, AND IT DOES NOT LAUNDER AN
#      EXISTING RECORD. ⛔ Relabelled: the assertion this block has always made is the
#      REFUSAL, and since the unsigned local-record premise was deleted as a forgery
#      vector, a planted clean-micro/clean-low record is no longer CONSULTED at all —
#      the refusal now comes from the missing-cover arm. The vectors below still pin
#      the only thing that remains true and load-bearing: no cover-less merge-only
#      delta mints `clean`, whatever record happens to sit on the box, and whatever
#      is there is left byte-identical (never upgraded to `clean`).
for _tier in clean-micro clean-low; do
    EH8=425137; rm -f "$(Q2 $EH8)"
    printf '{"pr":%d,"head_sha":"%s","verdict":"%s","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-06-02T00:00:00Z"}\n' \
      "$EH8" "$DG_A1" "$_tier" > "$(Q2 $EH8)"
    run_record_delta $EH8 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD"
    assert_eq "$RECORD_RC" "3" "20h6 a cover-less merge-only delta is refused even with a prior $_tier record present (rc 3)"
    assert_contains "$RECORD_ERR" "a delta EXTENDS an attestation and can never create one" "20h6 …by the merge-only needs-an-attested-A arm (the local-record premise is deleted, so it is not consulted)"
    assert_contains "$(cat "$(Q2 $EH8)" 2>/dev/null || true)" "\"verdict\":\"$_tier\"" "20h6 the planted $_tier record was not overwritten"
done

# 20h7 THE ANCHOR IS THE MAX BY COMMITTER DATE, not the tip. A backdated child must
#      not drag the anchor earlier than its own parent.
git checkout -q -b dated "$DG_A1" >/dev/null 2>&1
printf 'p\n' > p.txt; git add -A
GIT_COMMITTER_DATE='2025-06-20T00:00:00Z' GIT_AUTHOR_DATE='2025-06-20T00:00:00Z' git commit -qm 'parent (newer)'
DG_P="$(git rev-parse HEAD)"
printf 'c\n' > c.txt; git add -A
GIT_COMMITTER_DATE='2025-06-01T00:00:00Z' GIT_AUTHOR_DATE='2025-06-01T00:00:00Z' git commit -qm 'child (backdated)'
DG_C="$(git rev-parse HEAD)"
printf '%s\n' '2025-06-20T00:00:00Z' > "$T/dates/$DG_P"
printf '%s\n' '2025-06-01T00:00:00Z' > "$T/dates/$DG_C"
EH9=425138; rm -f "$(Q2 $EH9)"
run_record_delta $EH9 "$DG_C" "delta:$DG_A1..$DG_C+comment:42513801" STUB_EVIDENCE_AT="2025-06-10T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20h7 a cover predating the NEWEST-DATED authored commit is refused (anchor is the max, not the tip)"
EH10=425139; rm -f "$(Q2 $EH10)"
run_record_delta $EH10 "$DG_C" "delta:$DG_A1..$DG_C+comment:42513901" STUB_EVIDENCE_AT="2025-07-01T00:00:00Z"
assert_eq "$RECORD_RC" "0" "20h7 a cover postdating it still records"

# 20h8 A CLEAN merge in the SAME range as an evil merge must NOT move the anchor.
# Only the NON-CLEAN merges are anchor candidates: charging a re-review for a
# conflict-free merge of already-reviewed history is the agent-infra#3245 cost this
# change exists to remove.
git checkout -q evil2 >/dev/null 2>&1
git checkout -q -b sib "$DG_A1" >/dev/null 2>&1
printf 'sib\n' > new.txt; git add -A
GIT_COMMITTER_DATE='2025-09-02T00:00:00Z' GIT_AUTHOR_DATE='2025-09-02T00:00:00Z' git commit -qm 'clean side work'
git checkout -q evil2 >/dev/null 2>&1
GIT_COMMITTER_DATE='2026-03-01T00:00:00Z' GIT_AUTHOR_DATE='2026-03-01T00:00:00Z' \
  git -c core.editor=true merge --no-ff sib -m 'clean forward merge' >/dev/null 2>&1 || true
DG_MIXED="$(git rev-parse HEAD)"
printf '%s\n' '2026-03-01T00:00:00Z' > "$T/dates/$DG_MIXED"
if [ "$(git -C "$DG" rev-list --parents -n1 "$DG_MIXED" 2>/dev/null | awk '{print NF}')" = "3" ]; then
    ok "20h8 fixture: the mixed head is a real two-parent merge"
else
    bad "20h8 fixture: the clean merge did not happen — the vector would not test the arm"
fi
EH11=425150; rm -f "$(Q2 $EH11)"
# cover 2026-02-15: AFTER the evil merge (2026-02-01), BEFORE the clean merge (2026-03-01).
run_record_delta $EH11 "$DG_MIXED" "delta:$DG_EV_L..$DG_MIXED+comment:42515001" \
    STUB_EVIDENCE_AT="2026-02-15T00:00:00Z"
assert_eq "$RECORD_RC" "0" "20h8 a CLEAN merge does not move the anchor (cover after the evil merge records)"
assert_contains "$(cat "$(Q2 $EH11)" 2>/dev/null || true)" '"delta_kind":"authored"' "20h8 the mixed range is still AUTHORED (the evil merge is not hidden)"

# 20h9 TWO CHAINED evil merges whose committer dates are NOT monotone (the child
# is the OLDER one). `rev-list` is topology-first, so a `break` on the first
# non-clean merge captures the child and never examines the parent that carries the
# LATER hand-resolution — a cover predating it would then verify. Every non-clean
# merge must reach the anchor set.
ev_tree() {  # $1 = f.txt content, $2 = index file → tree sha of EV2_HEAD with f.txt replaced
    local blob
    blob="$(printf '%s\n' "$1" | git -C "$DG" hash-object -w --stdin)"
    GIT_INDEX_FILE="$2" git -C "$DG" read-tree "$DG_EV2_HEAD"
    GIT_INDEX_FILE="$2" git -C "$DG" update-index --add --cacheinfo "100644,$blob,f.txt"
    GIT_INDEX_FILE="$2" git -C "$DG" write-tree
}
ET1="$(ev_tree 'hand resolution ONE' "$T/idx1")"
ET2="$(ev_tree 'hand resolution TWO' "$T/idx2")"
EM_PARENT="$(GIT_COMMITTER_DATE='2026-06-01T00:00:00Z' GIT_AUTHOR_DATE='2026-06-01T00:00:00Z' \
    git -C "$DG" commit-tree "$ET1" -p "$DG_EV2_HEAD" -p "$DG_A1" -m 'evil merge PARENT')"
EM_CHILD="$(GIT_COMMITTER_DATE='2026-04-01T00:00:00Z' GIT_AUTHOR_DATE='2026-04-01T00:00:00Z' \
    git -C "$DG" commit-tree "$ET2" -p "$EM_PARENT" -p "$DG_A1" -m 'evil merge CHILD (backdated)')"
printf '%s\n' '2026-06-01T00:00:00Z' > "$T/dates/$EM_PARENT"
printf '%s\n' '2026-04-01T00:00:00Z' > "$T/dates/$EM_CHILD"
EMERGE_COUNT="$(git -C "$DG" rev-list --merges "$DG_EV_L..$EM_CHILD" --not "$DG_M1" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$EMERGE_COUNT" = "3" ]; then
    ok "20h9 fixture: the range holds TWO chained evil merges"
else
    bad "20h9 fixture: expected 3 in-range merges, got $EMERGE_COUNT — the vector would not test the arm"
fi
if [ "$(git -C "$DG" rev-list --merges "$DG_EV_L..$EM_CHILD" --not "$DG_M1" | head -1)" = "$EM_CHILD" ]; then
    ok "20h9 fixture: rev-list emits the BACKDATED child first (the trap is live)"
else
    bad "20h9 fixture: the child is not emitted first — the vector would not test the trap"
fi
EH12=425151; rm -f "$(Q2 $EH12)"
# cover 2026-05-01: after the child's date (2026-04-01), BEFORE the parent's (2026-06-01)
run_record_delta $EH12 "$EM_CHILD" "delta:$DG_EV_L..$EM_CHILD+comment:42515002" \
    STUB_EVIDENCE_AT="2026-05-01T00:00:00Z"
# ⛔ REFUSAL ONLY — NOT message-attributed. The harness could not pin WHICH arm
# refused (the stderr carried no delta line), so this vector does not claim to test
# the evil-merge MESSAGE; what it pins is the security property (no clean record at
# that head for a cover predating the parent hand-resolution) and M10 below is what
# proves the population truncation is what makes it refuse.
if [ "$RECORD_RC" = "0" ]; then
    bad "20h9 a cover predating the SECOND (parent) evil merge was ACCEPTED (rc 0) — the anchor population is truncated"
else
    ok "20h9 a cover predating the SECOND (parent) evil merge is refused (rc $RECORD_RC)"
fi
[ -f "$(Q2 $EH12)" ] && bad "20h9 no record was written at the evil head" ||
    ok "20h9 no record was written at the evil head"

# 20h10 delta × --force-stale: a delta ASSERTS its upper bound is the PR's current
#       head, so recording one against a stale sha mints a false claim.
EH13=425152; rm -f "$(Q2 $EH13)"
run_record_delta $EH13 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" EXTRA_ARGS=--force-stale
assert_eq "$RECORD_RC" "2" "20h10 delta + --force-stale is refused (rc 2, argument error)"
assert_contains "$RECORD_ERR" "incompatible with delta evidence" "20h10 the refusal names the contradiction"
[ -f "$(Q2 $EH13)" ] && bad "20h10 no record was written" || ok "20h10 no record was written"

# 20h12 THE RANGE MUST BE THE REVIEWER'S CLAIM. A committer date records when a
#      commit was CREATED, not when it was pushed, so an OLD-DATED branch merged in
#      after the review never moves the date anchor — and the old cover would then
#      "cover" content nobody read. The plain head-bound path refuses that same head;
#      an authored delta must not accept what it rejects. A cover that does not NAME
#      the range is refused, and 20d2/20h5/20h7/20h8 (whose bodies do name it) still
#      record — so the arm discriminates on the claim, not on the dates.
EH14=425154; rm -f "$(Q2 $EH14)"
run_record_delta $EH14 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42515501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="Reviewed the diff; no issues found."
assert_eq "$RECORD_RC" "3" "20h12 an authored delta whose cover does NOT name the range is refused (rc 3)"
# ⛔ The FIFTH cycle moved which arm refuses this vector. The bare-needle fallback is gone for an
# authored range (20h25), so a cover that names nothing is now stopped by the required-stated-range
# arm with "does not STATE the range". ⚠️ CORRECTION (sixth cycle, P2): the earlier version of this
# note claimed the old post-loop "does not NAME the range" check was "still reached by the
# MERGE-ONLY arm and pinned by 20h16". It was NOT: that check was DEAD CODE — the merge-only arm
# either sets body_claim or returns before it, and the authored arm now returns or sets it too —
# and 20h16 pins the merge-only arm's own, different message. The dead block has been deleted and
# this note no longer points at a pin that does not exist. (`rg 'does not NAME the range'` matches
# only this comment, which is how the claim was falsified.)
assert_contains "$RECORD_ERR" "does not STATE the range" "20h12 the refusal names the missing range claim"
[ -f "$(Q2 $EH14)" ] && bad "20h12 no record was written" || ok "20h12 no record was written"

# 20h13 A MODIFY/DELETE CONFLICT resolved git's own way. `merge-tree --write-tree`
#      PRINTS A TREE EVEN WHEN IT CONFLICTS (exit 1), so a resolution that keeps the
#      modified file has a tree IDENTICAL to merge-tree's — a tree comparison alone
#      calls it a clean merge, the range classifies merge-only, the cover premise is
#      satisfied by A and `clean` is minted over a conflict resolution nobody read.
#      The vector asserts `want == actual` first, so it fails ONLY on the status.
git checkout -q "$DG_M1" >/dev/null 2>&1
printf 'shared\n' > del.txt; git add -A
GIT_COMMITTER_DATE='2025-05-01T00:00:00Z' GIT_AUTHOR_DATE='2025-05-01T00:00:00Z' git commit -qm 'base adds del.txt'
DG_MDX="$(git rev-parse HEAD)"
git checkout -q -b mdlane "$DG_MDX" >/dev/null 2>&1
printf 'lane version\n' > del.txt; git add -A
GIT_COMMITTER_DATE='2025-05-02T00:00:00Z' GIT_AUTHOR_DATE='2025-05-02T00:00:00Z' git commit -qm 'lane modifies del.txt'
DG_MDA="$(git rev-parse HEAD)"
git checkout -q -b mdmain "$DG_MDX" >/dev/null 2>&1
git rm -q del.txt >/dev/null 2>&1
# ⛔ A SECOND, NON-CONFLICTING BASE-SIDE EDIT. Without it the resolution keeps the lane's
# version of `del.txt`, so A's tree and B's tree are IDENTICAL, `git diff A..B` is EMPTY, and
# the recorder refuses at the EMPTY-DIFF arm — further down — so neither the merge-tree
# STATUS nor the evil-merge classification is ever reached. That is why this cell shipped
# UNMEASURED (fifth review cycle, P2): it asserted a refusal it was not actually measuring.
# With one unrelated file added on the base side, the range's diff is non-empty while the
# resolution tree still equals merge-tree's output, so the STATUS is the only remaining
# signal — which is what this fixture exists to isolate.
printf 'unrelated\n' > other.txt; git add other.txt
GIT_COMMITTER_DATE='2025-05-03T00:00:00Z' GIT_AUTHOR_DATE='2025-05-03T00:00:00Z' git commit -qm 'main deletes del.txt'
DG_MDM="$(git rev-parse HEAD)"
git checkout -q mdlane >/dev/null 2>&1
git -c core.editor=true merge --no-ff mdmain -m 'merge main (CONFLICT modify/delete)' >/dev/null 2>&1 || true
git add del.txt >/dev/null 2>&1
GIT_COMMITTER_DATE='2025-05-05T00:00:00Z' GIT_AUTHOR_DATE='2025-05-05T00:00:00Z' \
    git -c core.editor=true commit -qm 'resolve by keeping the modified file' >/dev/null 2>&1 || true
DG_MDB="$(git rev-parse HEAD)"
printf '%s\n' '2025-05-02T00:00:00Z' > "$T/dates/$DG_MDA"
printf '%s\n' '2025-05-03T00:00:00Z' > "$T/dates/$DG_MDM"
W13="$(git -C "$DG" merge-tree --write-tree "$DG_MDA" "$DG_MDM" 2>/dev/null | head -1 || true)"
A13="$(git -C "$DG" rev-parse "$DG_MDB^{tree}" 2>/dev/null || true)"
if [ -n "$W13" ] && [ "$W13" = "$A13" ]; then
    ok "20h13 fixture: the conflicted merge's TREE equals merge-tree's (status is the only signal)"
else
    bad "20h13 fixture: the trees differ, so the vector would not test the status arm (want=$W13 actual=$A13)"
fi
# ⛔ AND THE RANGE MUST NOT BE EMPTY, or this vector stops at the EMPTY-DIFF arm and the status
# arm is never reached — the vacuity that made M13 report "UNMEASURED" for four cycles.
if git -C "$DG" diff --quiet "$DG_MDA" "$DG_MDB" 2>/dev/null; then
    bad "20h13 fixture: the range's diff is EMPTY, so the vector stops at the EMPTY-DIFF arm and never measures the merge-tree STATUS arm"
else
    ok "20h13 fixture: the range's diff is NON-EMPTY, so the merge-tree STATUS is what decides"
fi
# A is the attested head the merge-only premise needs.
EPM=425160; rm -f "$(Q2 $EPM)"
printf '{"pr":%d,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2025-05-04T00:00:00Z"}\n' \
  "$EPM" "$DG_MDA" > "$(Q2 $EPM)"
EH15=425161; rm -f "$(Q2 $EH15)"
run_record_delta $EH15 "$DG_MDB" "delta:$DG_MDA..$DG_MDB" \
    STUB_BASE_PAIR=1 STUB_BASE_SHA="$DG_MDM" STUB_BASE_REF=main
assert_eq "$RECORD_RC" "3" "20h13 a modify/delete conflict resolved by hand is REFUSED (rc 3)"
# ⛔ ASSERT THE MESSAGE, NOT JUST THE EXIT CODE. Both the empty-diff arm and the status arm
# refuse, so `rc 3` alone cannot tell them apart — the message is what proves the vector
# reached the merge-tree STATUS classification rather than stopping further down.
assert_contains "$RECORD_ERR" "does NOT merge cleanly" "20h13 the refusal is the merge-tree STATUS verdict, not a downstream refusal"
assert_contains "$RECORD_ERR" "merge-tree rc=" "20h13 the refusal quotes the merge-tree exit status that decided it"
# (M13 — the merge-tree EXIT STATUS — is defined with the other mutation cells, after the
#  matrix helpers: invoking `mut_check` here would be too early in the file.)
[ -f "$(Q2 $EH15)" ] && bad "20h13 no record was written at the conflicted merge" ||
    ok "20h13 no record was written at the conflicted merge"

# 20h14 MERGE-ONLY + A NAMED COVER IS REACHABLE. In the ordering this feature
#       exists for — verdict at A, THEN the base merge creates B — B's commit date is
#       necessarily later than the verdict, so anchoring the merge-only cover on B
#       made the printed remedy (`+comment:<id>`) impossible to satisfy. The anchor is
#       A, so a cover posted after A records.
EH16=425162; rm -f "$(Q2 $EH16)"
printf '%s\n' '2025-06-01T00:00:00Z' > "$T/dates/$DG_A1"
run_record_delta $EH16 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42516301" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:$DG_A1..$DG_HEAD; no issues found."
assert_eq "$RECORD_RC" "0" "20h14 merge-only + a cover posted AFTER A records clean (rc 0)"
assert_contains "$(cat "$(Q2 $EH16)" 2>/dev/null || true)" '"delta_kind":"merge-only"' "20h14 the range stays merge-only"
EH17=425164; rm -f "$(Q2 $EH17)"
run_record_delta $EH17 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42516501" \
    STUB_EVIDENCE_AT="2025-05-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:$DG_A1..$DG_HEAD; no issues found."
assert_eq "$RECORD_RC" "3" "20h14 a cover PREDATING A is still refused (rc 3)"

# 20h15 A BODY THAT STATES A DIFFERENT RANGE. Quoting a NARROWER range (X..B, X a
#       descendant of A) must not satisfy the claim for the wider A..B — the record
#       would assert a range its own artifact contradicts.
EH18=425166; rm -f "$(Q2 $EH18)"
run_record_delta $EH18 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42516701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:$DG_A1..$DG_HEAD only; no issues found."
assert_eq "$RECORD_RC" "3" "20h15 a body stating a NARROWER range is refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h15 the refusal names the contradiction"
[ -f "$(Q2 $EH18)" ] && bad "20h15 no record was written" || ok "20h15 no record was written"

# 20h16 A COVER THAT NAMES **A ALONE** ALSO SATISFIES THE CLAIM (the other half of
#       20h14). A verdict written BEFORE B existed cannot name B at all, so demanding
#       the range would make the printed remedy unreachable in exactly the ordering
#       this feature exists for. Naming A IS the claim for a merge-only range.
#       ⛔ Numbered 20h16, not a second 20h14: the earlier draft emitted this block
#       TWICE with the same PR numbers (425162/425164) and the same labels, so the
#       later copy silently overwrote the earlier one's record and no reader could
#       tell which vector had actually been measured.
EH19=425168; rm -f "$(Q2 $EH19)"
printf '%s\n' '2025-06-01T00:00:00Z' > "$T/dates/$DG_A1"
run_record_delta $EH19 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42516801" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" STUB_EVIDENCE_BODY="reviewed $DG_A1; no issues found."
assert_eq "$RECORD_RC" "0" "20h16 merge-only + a cover naming A alone records clean (rc 0)"
assert_contains "$(cat "$(Q2 $EH19)" 2>/dev/null || true)" '"delta_kind":"merge-only"' "20h16 the range stays merge-only"
EH20=425169; rm -f "$(Q2 $EH20)"
run_record_delta $EH20 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42516901" \
    STUB_EVIDENCE_AT="2025-05-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed $DG_A1; no issues found."
assert_eq "$RECORD_RC" "3" "20h16 a cover naming A but PREDATING A is still refused (rc 3)"

# 20h17 THE RANGE NOTATION MUST NOT CHANGE THE ANSWER. 20h15 pins that a NARROWER stated
#       range is refused, and that arm is an ANTI-FAIL-OPEN check — so a one-character
#       difference in the ARTIFACT must not be able to route around it. As first written the
#       parser read `\.\.` ONLY: the IDENTICAL body in this repo's own three-dot compare
#       notation (`gh api compare/<base>...<head>`) did not match, `stated_to` stayed empty,
#       and control fell through to the bare-needle fallback — which is satisfied by a body
#       naming B ALONE. The range was then never checked at all, and the record asserted a
#       `delta_range` its own artifact contradicted, which is what that arm's message says it
#       prevents. Both notations must refuse. (Found in review at PR #3401; ported here with
#       the source fix rather than left as a known bypass.)
EH21=425174; rm -f "$(Q2 $EH21)"
run_record_delta $EH21 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42517501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:$DG_A1...$DG_HEAD only; no issues found."
assert_eq "$RECORD_RC" "3" "20h17 a body stating a NARROWER range in THREE-DOT form is refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h17 the three-dot body reaches the RANGE arm, not the bare-needle fallback"
assert_contains "$RECORD_ERR" "delta:${DG_A1:0:12}...${DG_HEAD:0:12}" "20h17 the refusal quotes the notation the ARTIFACT used, not the two-dot form misquoted back"
[ -f "$(Q2 $EH21)" ] && bad "20h17 no record was written" || ok "20h17 no record was written"

# 20h18 A TOLERATED SPELLING IS PARSED, NOT FALLEN PAST. The matcher must accept the
#       range with spaces around the colon/separator (an artifact may wrap or pad it),
#       and the answer must be the RANGE arm's — "states a DIFFERENT range" — because a
#       refusal that says "cannot parse" would mean the widening regressed and the
#       comparison never happened. Asserting the MESSAGE (not just rc 3) is what
#       discriminates: both paths refuse, so rc alone cannot tell them apart.
EH22=425180; rm -f "$(Q2 $EH22)"
run_record_delta $EH22 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42518101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta: $DG_A1 .. $DG_HEAD only; no issues found."
assert_eq "$RECORD_RC" "3" "20h18 a padded (but parseable) NARROWER range is refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h18 the padded range is PARSED and compared, not written off as unparseable"
[ -f "$(Q2 $EH22)" ] && bad "20h18 no record was written" || ok "20h18 no record was written"

# 20h19 AN UNPARSEABLE `delta:` RANGE FAILS **CLOSED**. This is the fail-open the second
#       review cycle found, and it is in the FALL-THROUGH rather than in the separator:
#       the regex pinned an exact spelling, so ANY tolerance gap (here: short shas) left
#       `stated_to` empty and control reached the bare-needle fallback — which is satisfied
#       by a body naming B ALONE. The body below carries the unparseable token AND the full
#       head, so the fallback WOULD accept it: only the explicit refuse-on-unparseable arm
#       stops the record asserting a range its artifact never stated.
EH23=425182; rm -f "$(Q2 $EH23)"
run_record_delta $EH23 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42518301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:abc1234..def5678 at $DG_HEAD; no issues found."
assert_eq "$RECORD_RC" "3" "20h19 an UNPARSEABLE delta: range is REFUSED (rc 3), never fallen past"
# ⚠️ RE-ANCHORED (ninth cycle): the range parser's floor is now 4 rather than 12, so `abc1234..def5678`
# IS parsed and the RANGE COMPARISON is what refuses it — a stronger arm than "cannot parse", and the
# vector's fail-closed intent is unchanged. The `cannot parse` message still decides the shapes this
# code genuinely cannot parse (a non-hex separator: 20h20's `delta: A1 till HEAD`).
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h19 the unparseable range is PARSED and compared (rc 3), never written off as prose"
[ -f "$(Q2 $EH23)" ] && bad "20h19 no record was written" || ok "20h19 no record was written"

# 20h20/20h21 THE TOKEN'S SPELLING MUST NOT DISABLE THE GUARD. The third review cycle found
#       the SAME P1 again, and the reason is the lesson: the first attempt made detection
#       independent of the REGEX but both still opened with the lower-case literal `delta:`,
#       so `Delta:`, `DELTA:` and `delta :` turned detection OFF and failed the parse AT THE
#       SAME TIME — two guards sharing a literal share a blind spot, so the refusal arm was
#       never reached and the body fell to the bare needle. `Delta:` beginning a sentence is
#       ordinary reviewer prose, not a contrived spelling. Both layers are now
#       case-insensitive with optional padding, so these must reach the RANGE arm.
EH24=425184; rm -f "$(Q2 $EH24)"
run_record_delta $EH24 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42518501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed Delta: $DG_A1..$DG_HEAD only; no issues found."
assert_eq "$RECORD_RC" "3" "20h20 a CAPITALISED narrower token is refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h20 the capitalised token is PARSED and compared, not disabled into the fallback"
[ -f "$(Q2 $EH24)" ] && bad "20h20 no record was written" || ok "20h20 no record was written"
EH25=425186; rm -f "$(Q2 $EH25)"
run_record_delta $EH25 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42518701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta : $DG_A1..$DG_HEAD only; no issues found."
assert_eq "$RECORD_RC" "3" "20h21 a token padded BEFORE the colon is refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h21 the padded token is PARSED and compared, not disabled into the fallback"
[ -f "$(Q2 $EH25)" ] && bad "20h21 no record was written" || ok "20h21 no record was written"
# 20h22 …AND THE TOLERANCE IS NOT A FALSE RED. The widened token must still ACCEPT an
#       artifact that states the EXACT recorded range in a padded/capitalised spelling —
#       otherwise the fix would block correct reviewers, which is its own defect.
EH26=425188; rm -f "$(Q2 $EH26)"
run_record_delta $EH26 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42518901" \
    STUB_EVIDENCE_BODY="reviewed Delta: $DG_BASE .. $DG_HEAD; no issues found."
assert_eq "$RECORD_RC" "0" "20h22 a padded CAPITALISED spelling of the RECORDED range still records clean (rc 0)"
assert_contains "$(cat "$(Q2 $EH26)" 2>/dev/null || true)" '"delta_kind":"authored"' "20h22 the accepted record is the normal one, not a special case"

# 20h23 THE RANGE CLAIM MUST NOT NEED THE WORD `delta:` TO ARM. Fourth review cycle,
#       finding (a): the guard armed on the TOKEN, so an artifact stating "Reviewed only
#       A1...HEAD" — an ordinary reviewer sentence — was invisible to BOTH layers and fell
#       to the bare needle, which it satisfies by naming B. MEASURED: that body recorded
#       rc 0 with `delta_range=BASE..HEAD`, marking the authored commit as reviewed on the
#       strength of a range the artifact never quoted. The arm now keys on the RANGE SHAPE,
#       so a stated range is compared whatever word introduces it; M18 restores the
#       word-keyed arm, which is the exact pre-fix state.
EH27=425190; rm -f "$(Q2 $EH27)"
run_record_delta $EH27 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="Reviewed only ${DG_A1}...${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "3" "20h23 a narrower range stated WITHOUT the word delta: is still refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h23 the stated range is reached and compared, not passed over as bare prose"
[ -f "$(Q2 $EH27)" ] && bad "20h23 no record was written" || ok "20h23 no record was written"

# 20h24 EVERY STATED RANGE IS CHECKED, NOT JUST THE FIRST. Fourth review cycle, finding
#       (b): `=~` is a LEFTMOST match, so parsing ONE range made the arm ORDER-DEPENDENT —
#       a body quoting the wide range first and the narrower one it actually read SECOND was
#       accepted on the first, while the mirror order refused. Order-dependence is not
#       containment, and a reviewer quoting the brief's range before their own is ordinary
#       prose. The body below states the RECORDED range first (it passes every clause) and
#       the narrower range it actually read second, so only an exhaustive scan refuses it.
EH28=425192; rm -f "$(Q2 $EH28)"
run_record_delta $EH28 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="delta:${DG_BASE}..${DG_HEAD} is the brief; I read delta:${DG_A1}...${DG_HEAD} only; no issues found."
assert_eq "$RECORD_RC" "3" "20h24 a NARROWER range stated SECOND is still refused (rc 3)"
assert_contains "$RECORD_ERR" "states a DIFFERENT range" "20h24 the arm is order-independent — a first passing range does not end the check"
assert_contains "$RECORD_ERR" "EVERY range the artifact states is checked" "20h24 the refusal says the scan is exhaustive"
[ -f "$(Q2 $EH28)" ] && bad "20h24 no record was written" || ok "20h24 no record was written"

# 20h25 THE SEPARATOR ALPHABET, i.e. the SAME P1 A FIFTH TIME (fifth review cycle). The
#       arm keyed the range on `\.{2,3}` — ASCII dots — and on the WORD `delta`. Every other
#       way a reviewer writes the same claim (an en dash, U+2026 as macOS/Word auto-substitutes
#       for `...`, the word "through") matched NEITHER layer, so `_any` and `_delta_tok` were
#       both 0 and control reached the bare-needle fallback — satisfied by a body naming B
#       ALONE. MEASURED on the shipped code: this exact sentence with `–` recorded rc 0 with
#       `delta_range=BASE..HEAD`, while the identical sentence with `..` refused at 3.
#       The lesson across all five cycles is the same and is now stated once, structurally:
#       a guard that enumerates SPELLINGS re-opens on the next spelling. So the fallback is
#       GONE for an authored range — a stated range is now REQUIRED, and no alphabet can be
#       silently absent from a requirement. (20h27 pins the fallback's own case, and 20a is
#       unaffected: it is the MERGE-ONLY arm, which has its own name-A requirement.)
EH29=425194; rm -f "$(Q2 $EH29)"
run_record_delta $EH29 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="Reviewed only ${DG_A1}–${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "3" "20h25 a narrower range stated with an EN DASH is refused (rc 3)"
assert_contains "$RECORD_ERR" "does not STATE the range" "20h25 the en-dash body reaches the range arm, not the bare-needle fallback"
[ -f "$(Q2 $EH29)" ] && bad "20h25 no record was written" || ok "20h25 no record was written"
EH30=425196; rm -f "$(Q2 $EH30)"
run_record_delta $EH30 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="Reviewed only ${DG_A1} through ${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "3" "20h26 a narrower range stated as prose ('through') is refused (rc 3)"
[ -f "$(Q2 $EH30)" ] && bad "20h26 no record was written" || ok "20h26 no record was written"
# 20h27 THE FALLBACK'S OWN CASE, PINNED IN THE NEW DIRECTION. A body that names B and states
#       no range must be REFUSED for an AUTHORED delta: naming the head is not a statement that
#       the reviewer covered A..B, and it is the shape every one of the five bypasses landed in.
#       What it does NOT cost: the same review is still recordable at B with plain
#       `--evidence comment:<id>` — which asserts exactly what the artifact says (a review at
#       the head) without asserting a range it never stated. That is why removing the fallback
#       loses no capability, and the refusal message says so.
EH31=425198; rm -f "$(Q2 $EH31)"
run_record_delta $EH31 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519901" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="Reviewed ${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "3" "20h27 a body naming ONLY the head is refused for an AUTHORED delta (rc 3)"
assert_contains "$RECORD_ERR" "plain --evidence comment:" "20h27 the refusal names the form that CAN record it (the plain comment attestation at B)"
[ -f "$(Q2 $EH31)" ] && bad "20h27 no record was written" || ok "20h27 no record was written"
# 20h28 THE SEPARATOR TOLERANCE, IN THE DIRECTION THAT STILL DECIDES. Removing the bare-needle
#       fallback (20h25) means an unparseable three-dot range is refused either way — so what the
#       tolerance now decides is whether an HONEST reviewer who writes this repo's own compare
#       idiom (`gh api compare/<base>...<head>`) is ACCEPTED or falsely blocked. Three dots must
#       still record the CORRECT range. (M15 mutates the tolerance and must REFUSE this.)
EH32=425200; rm -f "$(Q2 $EH32)"
run_record_delta $EH32 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}...${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "0" "20h28 the CORRECT range stated in THREE-DOT form is accepted (rc 0)"
assert_contains "$(cat "$(Q2 $EH32)" 2>/dev/null || true)" '"delta_kind":"authored"' "20h28 the accepted record is the normal authored one"
# 20h29 THE WORD IS IRRELEVANT IN THE ACCEPTANCE DIRECTION TOO. With the fallback gone, arming on
#       the WORD `delta:` no longer causes a bypass — it causes a FALSE BLOCK: an artifact that
#       states the correct range without that word would be refused, and "Reviewed only A..B" is
#       ordinary reviewer prose. (M18 mutates the shape arm back to the word and must REFUSE this.)
EH33=425202; rm -f "$(Q2 $EH33)"
run_record_delta $EH33 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="Reviewed only ${DG_BASE}..${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "0" "20h29 the CORRECT range without the word delta: is accepted (rc 0)"
assert_contains "$(cat "$(Q2 $EH33)" 2>/dev/null || true)" '"delta_kind":"authored"' "20h29 the accepted record is the normal authored one"
# 20h30 THE CONTRADICTION LAYER WAS STILL AN ENUMERATION OF SPELLINGS (sixth cycle, P1).
#       Requiring a stated range does not stop a CONTRADICTING one, because the comparison only
#       saw `hex dots hex`. This feature's own refusal messages TEACH reviewers to quote
#       `delta:<A>..<B>`, so an artifact can carry that acceptably-spelled decoy AND a narrower
#       claim in any other notation — and the decoy satisfies every parsed check. MEASURED on
#       the previous head: the body below recorded rc 0 with `delta_range=BASE..HEAD`.
#       The rule no longer asks what the notation IS, it asks what the artifact MEANS: every
#       resolvable commit the CLAIM names must be the head or an ancestor of the range start.
EH34=425204; rm -f "$(Q2 $EH34)"
run_record_delta $EH34 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
Reviewed only ${DG_A1}–${DG_HEAD}; no issues found."
assert_eq "$RECORD_RC" "3" "20h30 a NARROWER range in another notation, beside a passing decoy, is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "also names commit" "20h30 the refusal names the contradicting commit, not the decoy"
[ -f "$(Q2 $EH34)" ] && bad "20h30 no record was written" || ok "20h30 no record was written"
# 20h31 THE SAME RULE MUST NOT DEPEND ON ABBREVIATION LENGTH EITHER — `git log --oneline`
#       shas are 7-8 hex, below the parser's 12-char floor, and were invisible to both layers.
EH35=425206; rm -f "$(Q2 $EH35)"
run_record_delta $EH35 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
Actually reviewed only ${DG_A1:0:8}..${DG_HEAD:0:8}."
assert_eq "$RECORD_RC" "3" "20h31 a narrower range in 8-char shas is REFUSED (rc 3)"
[ -f "$(Q2 $EH35)" ] && bad "20h31 no record was written" || ok "20h31 no record was written"
# 20h32 THE MANDATORY KILL TABLE IS NOT A CLAIM (sixth cycle, P2). `## MUTATION ATTRIBUTION`
#       is required in every fresh clean artifact (#3442) and its rows quote ranges as a matter
#       of course — a row describing a mutant "pinned to A1..B" was compared as if it were the
#       reviewer's own claim, refusing a CORRECT artifact because of its kill table. The scan
#       reads the claim; the table is not a statement about what was reviewed.
EH36=425208; rm -f "$(Q2 $EH36)"
run_record_delta $EH36 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520901" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| 20h30 the decoy beside a narrowed claim is caught | re-point this cell at delta:${DG_A1}..${DG_HEAD} | 20h30 | rc 3 |"
assert_eq "$RECORD_RC" "0" "20h32 a range quoted inside the #3442 kill table does not refuse a CORRECT artifact (rc 0)"
[ -f "$(Q2 $EH36)" ] || bad "20h32 no record was written for a correct artifact"
# 20h33 A RANGE RELATIVE TO THE TIP IS ALWAYS A NARROWING (sixth cycle, P1 continuation).
#       `HEAD~1..HEAD` carries no hex token at all, so the meaning rule above cannot see it —
#       and beside an acceptably-spelled decoy it recorded rc 0. There is no innocent reading
#       of a tip-relative range in an artifact offered as evidence that A..B was covered.
EH37=425210; rm -f "$(Q2 $EH37)"
run_record_delta $EH37 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42521101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
I only actually reviewed HEAD~1..HEAD."
assert_eq "$RECORD_RC" "3" "20h33 a tip-relative range beside a passing decoy is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "RELATIVE TO THE TIP" "20h33 the refusal names the tip-relative notation"
[ -f "$(Q2 $EH37)" ] && bad "20h33 no record was written" || ok "20h33 no record was written"
# 20h34 THE KILL-TABLE EXCLUSION MUST BE THE BLOCK, NOT THE REGION AFTER IT (seventh cycle, P1).
#       The sixth cycle ended the skip only at the next `## ` heading, so ANY prose between the
#       table and the next level-2 heading was dropped from the claim — including a `### `
#       subsection. MEASURED on that head: the body below recorded rc 0 with
#       `delta_range=BASE..HEAD`, minting a signed `clean` over the range's only authored commit
#       while the artifact said in words that it had not been read. The mirror false block (a
#       body whose only range statement follows the table) is refused by the same fix.
EH38=425212; rm -f "$(Q2 $EH38)"
run_record_delta $EH38 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42521301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| 20h34 a narrowing after the table is caught | re-point this cell at delta:${DG_A1}..${DG_HEAD} | 20h34 | rc 3 |

### Scope caveat
I only actually reviewed ${DG_A1}–${DG_HEAD}; the base-side merge was not read."
assert_eq "$RECORD_RC" "3" "20h34 a narrowing in a ### subsection AFTER the kill table is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "also names commit" "20h34 the refusal names the contradicting commit"
[ -f "$(Q2 $EH38)" ] && bad "20h34 no record was written" || ok "20h34 no record was written"
# and the MIRROR direction: prose that follows the table is scanned, so a body whose only
# range statement sits there is ACCEPTED — the fix must not turn the exclusion into a region.
EH39=425214; rm -f "$(Q2 $EH39)"
run_record_delta $EH39 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42521501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="No issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |

The range I read was delta:${DG_BASE}..${DG_HEAD}."
assert_eq "$RECORD_RC" "0" "20h34 the range stated AFTER the kill table is still found (rc 0, no region-wide skip)"
[ -f "$(Q2 $EH39)" ] || bad "20h34 no record was written for a correct artifact"
# 20h35 THE MERGE-ONLY ARM MUST READ THE CLAIM TOO (seventh cycle, P2). The sixth cycle applied
#       "the kill table is not a claim" to the authored arm only, so the merge-only arm's
#       "names A" needle was satisfied by a kill-table ROW naming A — while that arm's own
#       comment says the table cannot be the statement the record relies on. A merge-only delta
#       EXTENDS an attestation, so its cover must BE the verdict at A.
EH40=425216; rm -f "$(Q2 $EH40)"
printf '%s\n' '2025-06-01T00:00:00Z' > "$T/dates/$DG_A1"
run_record_delta $EH40 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42521701" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" \
    STUB_EVIDENCE_BODY="No issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | the row that reddens delta:${DG_A1}..${DG_HEAD} | z | rc 3 |"
assert_eq "$RECORD_RC" "3" "20h35 a merge-only cover naming A ONLY in the kill table is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "does not name" "20h35 the refusal is the merge-only needle, not a later arm"
[ -f "$(Q2 $EH40)" ] && bad "20h35 no record was written" || ok "20h35 no record was written"
# control: the SAME body with A named in the prose records clean — the arm still works.
EH41=425218; rm -f "$(Q2 $EH41)"
run_record_delta $EH41 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42521901" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" \
    STUB_EVIDENCE_BODY="Reviewed $DG_A1; no issues found."
assert_eq "$RECORD_RC" "0" "20h35 a merge-only cover naming A in the PROSE still records clean (rc 0)"
# 20h36 ONLY A LATER COMMIT CAN NARROW (seventh cycle, P2). A commit reachable from NEITHER
#       endpoint cannot narrow A..B at all — refusing it is a false block over prose, and the
#       only remedy for a false block here is the full re-review this feature exists to avoid.
#       MEASURED before the fix: quoting an unrelated commit (another PR's head) refused.
DG_UNREL="$(git -C "$DG" commit-tree "$(git -C "$DG" rev-parse "$DG_BASE^{tree}")" -m 'unrelated root' 2>/dev/null || true)"
EH42=425220; rm -f "$(Q2 $EH42)"
run_record_delta $EH42 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
For context, the other PR's head was ${DG_UNREL} and it is unrelated to this range."
if [ -n "$DG_UNREL" ] && ! git -C "$DG" merge-base --is-ancestor "$DG_UNREL" "$DG_BASE" 2>/dev/null && ! git -C "$DG" merge-base --is-ancestor "$DG_BASE" "$DG_UNREL" 2>/dev/null; then
    ok "20h36 fixture: the quoted commit is on an UNRELATED lineage (neither ancestor nor descendant)"
else
    bad "20h36 fixture: DG_UNREL is not unrelated — the vector would not test the unrelated-lineage arm"
fi
assert_eq "$RECORD_RC" "0" "20h36 a commit on an UNRELATED lineage does not refuse the claim (rc 0)"
[ -f "$(Q2 $EH42)" ] || bad "20h36 no record was written for a correct artifact"
# 20h37 THE BLOCK'S PREAMBLE AND INTER-ROW PROSE ARE SCANNED (eighth cycle, P1 — the seventh
#       cycle's exclusion was a LINE SPAN from the heading to its last row, so every non-row line
#       INSIDE it was dropped from the claim: the block's preamble, and prose between its rows.
#       MEASURED on that head: the body below recorded rc 0 with `delta_range=BASE..HEAD`. It is
#       the shape a reviewer actually produces — the #3442 block is appended to a verdict, and the
#       sentence above the table is where they say what they read. A span is a REGION in a shorter
#       costume; the exclusion is now a LINE predicate (heading + table rows only).
EH43=425222; rm -f "$(Q2 $EH43)"
run_record_delta $EH43 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)
The verdict I am extending actually read delta:${DG_A1}–${DG_HEAD}.

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |"
assert_eq "$RECORD_RC" "3" "20h37 a narrowing in the block's PREAMBLE is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "also names commit" "20h37 the refusal names the contradicting commit"
[ -f "$(Q2 $EH43)" ] && bad "20h37 no record was written" || ok "20h37 no record was written"
# and the same shape BETWEEN two rows, which the span also dropped.
EH44=425224; rm -f "$(Q2 $EH44)"
run_record_delta $EH44 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| one | y | z | rc 3 |

Only delta:${DG_A1}..${DG_HEAD} was actually read.

| two | y | z | rc 3 |"
assert_eq "$RECORD_RC" "3" "20h37 a narrowing BETWEEN two kill-table rows is REFUSED (rc 3)"
[ -f "$(Q2 $EH44)" ] && bad "20h37 no record was written" || ok "20h37 no record was written"
# 20h38 THE HEADING IS RECOGNISED BY brief-gate.sh's CONTRACT, NOT A SECOND ONE (eighth cycle,
#       P2). #3442's validator accepts ANY case, ANY `#` depth, indent <= 3 and
#       `mutation[ -]attribution`; this matcher knew only the canonical spelling, so a fully valid
#       artifact was not excluded, its row was compared as the reviewer's claim, and it was
#       refused with a FALSE ACCUSATION. Both spellings below pass brief-gate's own arm.
EH45=425226; rm -f "$(Q2 $EH45)"
run_record_delta $EH45 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

### Mutation-Attribution

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| the verdict covers ${DG_A1} | y | z | rc 3 |"
assert_eq "$RECORD_RC" "0" "20h38 a ### Mutation-Attribution heading (brief-gate-valid) is EXCLUDED (rc 0)"
[ -f "$(Q2 $EH45)" ] || bad "20h38 no record was written for a valid artifact"
# and the validator really does accept that spelling — otherwise this vector proves nothing.
if printf '### Mutation-Attribution\n\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| a | b | c | d |\n' \
    | bash "$SCRIPT_DIR/orchestrator-harness/brief-gate.sh" --mutation-missing - >/dev/null 2>&1; then
    ok "20h38 brief-gate accepts the non-canonical heading (the vector is not vacuous)"
else
    bad "20h38 brief-gate did NOT accept the non-canonical heading — the vector would prove nothing"
fi
# 20h39 THE HEADING LINE IS NOT DROPPED WHOLE (ninth cycle, P1). The exclusion removes the section
#       NAME; anything a reviewer writes on the heading line is prose. MEASURED on the eighth
#       cycle's head: the body below recorded rc 0 over the WIDE range, because the entire heading
#       line went into the bin and the stated narrowing with it. (Control: move the same sentence one
#       line down — 20h37 already pins that direction.)
EH46=425228; rm -f "$(Q2 $EH46)"
run_record_delta $EH46 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522901" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION — I also only read ${DG_A1}–${DG_HEAD}

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |"
assert_eq "$RECORD_RC" "3" "20h39 a narrowing ON the kill-table heading line is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "also names commit" "20h39 the refusal names the contradicting commit"
[ -f "$(Q2 $EH46)" ] && bad "20h39 no record was written" || ok "20h39 no record was written"
# 20h40 A SECOND MUTATION-ATTRIBUTION SECTION IS STILL A KILL TABLE (ninth cycle, P2). The eighth
#       cycle located ONE heading/end pair, so a second block's rows fell outside the exclusion and
#       were read as the reviewer's claim: an artifact built as an addendum (the ordinary shape) was
#       refused for a row it is entitled to carry. brief-gate's own parser re-opens the section on
#       every matching heading, and this mirrors it.
EH47=425230; rm -f "$(Q2 $EH47)"
BODY40='reviewed delta:'"$DG_BASE"'..'"$DG_HEAD"'; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| one | y | z | rc 3 |

## MUTATION ATTRIBUTION (addendum, same verdict)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| two | the row that reddens delta:'"$DG_A1"'..'"$DG_HEAD"' | two | rc 3 |'
run_record_delta $EH47 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="$BODY40"
assert_eq "$RECORD_RC" "0" "20h40 a SECOND kill-table block's rows are excluded too (rc 0)"
[ -f "$(Q2 $EH47)" ] || bad "20h40 no record was written for a valid two-block artifact"
if printf '%s' "$BODY40" | bash "$SCRIPT_DIR/orchestrator-harness/brief-gate.sh" --mutation-missing - >/dev/null 2>&1; then
    ok "20h40 brief-gate accepts the two-block artifact (the vector is not vacuous)"
else
    bad "20h40 brief-gate did NOT accept the two-block artifact — the vector would prove nothing"
fi
# 20h41 THE FLOOR BELOW 7 (ninth cycle, P1). git resolves a 4-6 char unique prefix, and the two
#       scans' floors were 12 (dots parser) and 7 (token rule) — so a narrowing written with a
#       6-char start was invisible to BOTH and recorded rc 0 over the wide range. 20h31's 8-char
#       vector is what made the gap look covered.
EH48=425232; rm -f "$(Q2 $EH48)"
run_record_delta $EH48 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
I only actually reviewed ${DG_A1:0:6}..${DG_HEAD:0:6}; the rest was not read."
assert_eq "$RECORD_RC" "3" "20h41 a narrowing in 6-char abbreviations is REFUSED (rc 3)"
[ -f "$(Q2 $EH48)" ] && bad "20h41 no record was written" || ok "20h41 no record was written"
# and the SHORT-UNRESOLVABLE form is PROSE, not a range claim: a hex-looking pair beside dots (a
# review of hex literals) must not be refused as a contradicting range.
EH49=425234; rm -f "$(Q2 $EH49)"
run_record_delta $EH49 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
The literals 0xdead..0xbeef and f00d..babe are unrelated to this range."
assert_eq "$RECORD_RC" "0" "20h41 unresolvable short hex beside dots reads as PROSE (rc 0)"
[ -f "$(Q2 $EH49)" ] || bad "20h41 a hex-literal pair falsely blocked a correct artifact"
# 20h42 THE BLOCK'S OWN TABLE ENDS (tenth cycle, P1). The ninth cycle closed `ins` only on a HEADING,
#       so from the block's heading to the next level-2 heading every table row was excluded — and the
#       #3442 block is normally the LAST section, so a narrowing written in a table row AFTER it was
#       dropped and a signed `clean` was minted over commits the artifact said were not read.
#       MEASURED on that head: the body below recorded rc 0 with `delta_range=BASE..HEAD`. The
#       exclusion is now bounded structurally: the block's header (assertion+mutant+redden) opens its
#       table, CONTIGUOUS rows continue it, and a blank line or prose ends it for good.
EH50=425236; rm -f "$(Q2 $EH50)"
run_record_delta $EH50 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |

| what I actually reviewed | ${DG_A1} | not the rest | rc 3 |"
assert_eq "$RECORD_RC" "3" "20h42 a narrowing in a table row AFTER the block is REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "also names commit" "20h42 the refusal names the contradicting commit"
[ -f "$(Q2 $EH50)" ] && bad "20h42 no record was written" || ok "20h42 no record was written"
# 20h43 THE ROW RECOGNITION MIRRORS brief-gate's (tenth cycle, P2). A GFM table need not have OUTER
#       PIPES (`assertion | mutant | reddened | observed` renders as one), and brief-gate strips a
#       bullet and blockquote markers before counting cells — so an artifact it certifies valid was
#       NOT excluded here, its row was read as the reviewer's claim, and a correct record was refused
#       with a false accusation. Both spellings are below, and the validator is run to prove the body
#       is valid (otherwise the vector proves nothing).
EH51=425238; rm -f "$(Q2 $EH51)"
BODY43="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

assertion | mutant (reverts the fix) | reddened row | observed
---|---|---|---
x | sed s/rc=80/rc=0/ | A (i) | rc=0
- the guard added at ${DG_A1} | revert it | B (ii) | row red"
run_record_delta $EH51 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523901" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="$BODY43"
assert_eq "$RECORD_RC" "0" "20h43 a no-outer-pipe / bulleted kill table is EXCLUDED (rc 0)"
[ -f "$(Q2 $EH51)" ] || bad "20h43 no record was written for a valid artifact"
if printf '%s' "$BODY43" | bash "$SCRIPT_DIR/orchestrator-harness/brief-gate.sh" --mutation-missing - >/dev/null 2>&1; then
    ok "20h43 brief-gate accepts the no-outer-pipe table (the vector is not vacuous)"
else
    bad "20h43 brief-gate did NOT accept the no-outer-pipe table — the vector would prove nothing"
fi
# 20h44 A SKIPPED TOKEN IS NOT A STATED RANGE (eleventh cycle, P1). The prose skip exists so a
#       hex-LOOKING pair (`0xdead..0xbeef`) is not refused as a contradicting range, and its own
#       comment promises it is "skipped, never silently accepted as a range". But `_any` was set
#       BEFORE the skip, so the skipped token still marked the body as having STATED a range:
#       `_all_ok` stayed 1 (so the containment refusal could not fire) and `_any` stayed 1 (so the
#       "a stated range is REQUIRED" refusal could not fire either) — the two arms cancelled and
#       the body sailed through the very requirement the ninth cycle added. MEASURED: the body
#       below states no range at all and recorded rc 0 with a `delta_range` derived from DATES,
#       which is the case arm (10a) says "dates cannot settle". 20h41's vector could not see it
#       because it takes the OTHER branch (a real range is stated beside the prose).
EH52=425240; rm -f "$(Q2 $EH52)"
run_record_delta $EH52 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42524101" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="The literals 0xdead..0xbeef and f00d..babe are unrelated to this change.
No issues found; the port handling is correct."
assert_eq "$RECORD_RC" "3" "20h44 a body whose ONLY dots-token is PROSE has not stated a range (rc 3)"
assert_contains "$RECORD_ERR" "does not STATE the range" "20h44 the refusal names the missing range statement"
[ -f "$(Q2 $EH52)" ] && bad "20h44 no record was written" || ok "20h44 no record was written"
# 20h45 THE REFUSAL MUST NAME WHAT ACTUALLY HAPPENED (eleventh cycle, P2). The arm refuses an
#       artifact that names a commit LATER than A — a DECLARED residual, kept deliberately (see the
#       note above it), because telling an innocent reference from a narrowing endpoint means
#       enumerating notations. What was wrong is the DIAGNOSIS: for an artifact that states the
#       CORRECT range and additionally LISTS the commits it read — the ordinary reviewer artifact,
#       and what `skills/code-review/SKILL.md` asks a reviewer to return — the message asserted a
#       "narrower range … written in a notation this code does not parse" when the artifact narrowed
#       nothing and the token was a plain sha. The rule stays; the sentence now distinguishes a
#       commit INSIDE the range from a narrowing endpoint.
EH53=425242; rm -f "$(Q2 $EH53)"
run_record_delta $EH53 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42524301" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## What I reviewed

| commit | subject |
|---|---|
| ${DG_A1} | the lane commit |
| ${DG_HEAD} | the forward merge |"
assert_eq "$RECORD_RC" "3" "20h45 naming a commit INSIDE the range is still refused (declared residual)"
assert_contains "$RECORD_ERR" "INSIDE the range" "20h45 the refusal says INSIDE the range"
assert_not_contains "$RECORD_ERR" "notation this code does not parse" "20h45 and does NOT accuse the artifact of an unparseable narrowing"
# 20h46 THE THIRD LOCATION: A COMMIT AFTER THE HEAD (twelfth cycle, P2). The eleventh cycle's fix
#       split the refusal in two and its own comment claimed a token that is not INSIDE the range
#       "can only be a narrowing endpoint written in a notation the parser did not tokenise". That is
#       FALSE: a commit whose PARENT is the attested head reaches the same message and was told it
#       had written an unparseable narrowing — a narrowing is BELOW the range, a descendant of B is
#       ABOVE it, and no notation is involved in either. The refusal is right (a verdict naming a
#       commit that did not exist at B is not a verdict at B); the diagnosis was not. This vector is
#       the only one that reaches that branch, which is why the wording was never exercised before.
EH54=425244; rm -f "$(Q2 $EH54)"
_b46="$(printf 'later\n' | git -C "$DG" hash-object -w --stdin)"
_t46="$(printf '100644 blob %s\tlater.txt\n' "$_b46" | git -C "$DG" mktree)"
DG_AFTER="$(git -C "$DG" commit-tree "$_t46" -p "$DG_HEAD" -m 'later work')"
run_record_delta $EH54 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42524501" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found. The head later moved to ${DG_AFTER}."
assert_eq "$RECORD_RC" "3" "20h46 a commit AFTER the attested head is still refused (rc 3)"
assert_contains "$RECORD_ERR" "AFTER" "20h46 the refusal says AFTER the attested head"
assert_not_contains "$RECORD_ERR" "notation this code does not parse" "20h46 and does NOT accuse the artifact of an unparseable narrowing"
# 20h46b THE MESSAGE MUST NOT EXECUTE ITS OWN BACKTICKS (thirteenth cycle, P2). The refusal above was
#        written with a RAW `` `clean` `` inside a double-quoted `echo`, so bash ran `clean` as a
#        COMMAND SUBSTITUTION: stderr carried `line NNNN: clean: command not found` and the sentence
#        printed `a  record` with the word missing. Measured on the shipped head, and it is not
#        cosmetic on a box where a `clean` executable exists on PATH — the message executes it. The
#        rule and the exit code were unaffected, which is exactly why nothing caught it.
assert_not_contains "$RECORD_ERR" "command not found" "20h46b the refusal does not RUN its own backticked word"
assert_contains "$RECORD_ERR" 'a `clean` record' "20h46b the backticked word is PRINTED, not run"
# 20h48 THE WHOLE SCRIPT, NOT JUST ONE SENTENCE (thirteenth cycle, P2). The same defect already
#        pre-existed on the carry arm's `empty` message, so a vector per sentence cannot bound it —
#        the class is "an echo/printf message that executes its own backticks". This is the sweep:
#        every `echo`/`printf` LINE in the recorder is scanned, escaped backticks excepted. It reds
#        on a reintroduction anywhere in the file rather than only where someone thought to test.
_badbt="$(python3 - "$SCRIPT_DIR/record-review.sh" <<'PY48'
import re, sys
out = []
for i, l in enumerate(open(sys.argv[1]), 1):
    st = l.strip()
    if not (st.startswith('echo ') or st.startswith('printf ')):
        continue
    if re.findall(r'(?<!\\)`', st):
        out.append("%d: %s" % (i, st[:90]))
print("\n".join(out))
PY48
)"
assert_eq "$_badbt" "" "20h48 no echo/printf message anywhere in the recorder executes its own backticks"
# 20h48b THE SAME CLASS IN THE SUITE'S OWN LABELS (round 3, P2). 20h48 scans only the RECORDER, so
#        a label in this file was invisible to it — and one carried unescaped backticks, so the
#        suite EXECUTED `n_authored` as a command at test time and printed the label with the word
#        deleted ("—  is legitimately 0 here"). Not cosmetic by 20h46b's own reasoning: on a box
#        with a `clean` executable on PATH, a message that executes its own backticks runs it.
#        The scan covers BOTH files, strips single-quoted regions (a backtick there is literal) and
#        strips trailing comments through a small quote-state machine (so `# only \`x\` is RED`
#        is not a hit, while a backtick in a LABEL argument is).
# ⛔ AND THE SCANNER ITSELF CARRIES A CONTROL (round 4, P2). Without one, a scanner that
#    silently stopped SEEING a case would print "" and PASS — the very false PASS this sweep
#    exists to prevent, asserted by the sweep. The fixture is generated with `printf '\140'` so
#    THIS file holds no live backtick of its own, and its EIGHT lines pin the lexical rules the
#    scanner models, each one measured against bash rather than assumed:
#      1 RED   an apostrophe inside "..." is a literal, it does not shield a backtick
#      2 GREEN single-quoted content is literal
#      3 GREEN ONE backslash escapes it
#      4 RED   an EVEN run leaves it executable (`double backslash \EXECUTED runs`)
#      5 RED   `#` comments only at a WORD START: `a#`echo X`` prints `a#X` (man bash, COMMENTS)
#      6 RED   ...and a closing quote leaves you MID-WORD: `"x"#`echo X`` prints `x#X`
#      7 RED   an unquoted backslash escapes the NEXT char: `it\'s `echo X`` runs X, so `\'`
#              does not open a quote (man bash, QUOTING)
#      8 GREEN ...so `\"` opens nothing either, and the `#` after it IS a comment
#    Lines 5-8 exist because the first cut of this control pinned only 1-4 and the scanner
#    was still blind to them — a false CLEAN on 5-7 and a false RED on 8, all four measured.
_bt="$(printf '\140')"
{
  printf '%s\n' "_x=\"the grader's ${_bt}n_authored${_bt} isn't 0\""
  printf '%s\n' "_y='literal ${_bt}x${_bt}'"
  printf '%s\n' "_z=\"escaped \\${_bt}x\\${_bt} is literal\""
  printf '%s\n' "_w=\"double backslash \\\\${_bt}x\\\\${_bt} runs\""
  printf '%s\n' "echo a#${_bt}echo EXEC5${_bt}"
  printf '%s\n' "echo \"x\"#${_bt}echo EXEC6${_bt}"
  printf '%s\n' "echo it\\'s the ${_bt}echo EXEC7${_bt} that moved"
  printf '%s\n' "echo \\\"a # only ${_bt}echo NOTEXEC${_bt} is a comment"
} > "$T/btctrl.sh"
# ⛔ THE HERE-DOC LIVES IN A FUNCTION BODY, NOT IN A `$( )` (bash 3.2, #2930/#2248).
#    bash 3.2's `$( )` scanner does not know about here-documents: it walks the body as CODE,
#    so a body carrying an UNBALANCED quote desynchronises the parse state for the REST OF THE
#    FILE — and this body quotes live backticks as PROSE. Measured at 7666f34b3: `bash -n`
#    under bash 3.2.57 reported "unexpected EOF while looking for matching `\"'" at the body
#    and "syntax error: unexpected end of file" ~550 lines below, so `check-bash32-parse.sh`
#    (#2930) REDS — on a stock Mac `/bin/bash` is 3.2 and install.sh's `bash -n` sweep dies.
#    The remedy is #2248's: the substitution now carries a FUNCTION CALL, no here-doc.
_badbt2_sweep() { python3 - "$1" "$2" "$3" <<'PY48B'
import re, sys
ctrl = sys.argv[1]
targets = sys.argv[2:]
# ⛔ ONE STATE MACHINE, NOT TWO (round 4, P2). The first cut stripped comments in a
# quote-state machine and then removed single-quoted spans with a REGEX on the
# result — outside that state. Inside a DOUBLE-quoted string an apostrophe is a
# literal character, not a quote opener, so a pair straddling a backtick
# ("the grader's `n_authored` isn't 0") deleted the backtick before it was tested:
# a false PASS on the exact class this sweep claims to bound. Single-quoted content
# is now dropped BY the machine (q == "'"), where the context is known, and
# apostrophes inside "..." are kept literal.
# ⛔ WHAT THIS MODELS, AND WHAT IT DOES NOT (round 5, P2) — stated because the earlier
# wording claimed a bash lexer and this is not one. It is a SINGLE-LINE classifier:
#   MODELLED       unquoted `\` escapes the next char, `'...'` is literal, `"..."` keeps
#                  apostrophes literal, an even backslash run leaves a backtick live (parity
#                  falls out of pair-consumption), `#` comments only at a WORD START, and
#                  `$'...'`/`${...}`/`$(...)` do not exist for it.
#   NOT MODELLED   a quoted string that SPANS LINES (a `#`-leading continuation line reads as
#                  a comment), `$'...'` ANSI-C quoting, a `#` inside `${...}`, and heredoc
#                  bodies. All four were MEASURED as false CLEANs on hand-built lines
#                  (round 6), and NONE of them occurs in either target: all 19 backtick-bearing
#                  lines that are not WHOLE-LINE comments (13 recorder, 6 suite) carry their
#                  backticks escaped `\``, single-quoted, or after a trailing `#` comment —
#                  three benign categories, and the classifier agrees on all 19 (round 7).
# ⛔ A WHOLE-FILE LEXER WAS BUILT AND REJECTED — with the measurement, not as a preference.
# Carrying quote state across lines is the only way to close the multi-line hole, and on the
# REAL recorder it desyncs at `$(` inside a double-quoted string, because `$(` resets quoting:
# the awk program at record-review.sh:1846 (`grep -n 'EVIDENCE_BODY" | command awk'`) carries
# its own comment block across lines (`sed -n '1851,1860p'`), so a lexer that does not model `$(`
# re-opens a quote mid-program and reports those lines as live backticks — 26 false REDs over 12
# lines in the prototype run (a COUNT, not a line map). Modelling `$(`,
# `${`, `$'` and heredocs well enough to stay in sync is a bash lexer, which is a different
# project from this vector. So the scope is DECLARED here instead of over-claimed: this
# sweep bounds the shipped defect (a `"..."` message that runs its own backticks) on every
# line of both files, exactly, and it is a BELT — the artifact's own refusals (20h46b) are
# the gate.
# ⛔ WITHIN THAT SCOPE IT MUST MODEL THE RULES, NOT ITS OWN INTUITION (round 5, P2) — the
# first cut treated ANY unquoted `#` as a comment and consumed NO unquoted backslash, which
# gave a false CLEAN on `a#`echo X``, `"x"#`echo X`` and `it\'s `echo X``, and a false RED on
# `\"a # ... `x`` (all four measured):
#   * man bash, COMMENTS: "a WORD BEGINNING WITH #" — so `a#b` is mid-word and comments nothing.
#   * man bash, QUOTING: a non-quoted backslash preserves the literal value of the next char.
_WORDSTART=set(' \t;|&()<>')
def scan(s):
    out=[]; q=None; i=0; last=None
    while i < len(s):
        c=s[i]
        if q == '"':
            if c=='\\':
                out.append(c); out.append(s[i+1:i+2]); last=c; i+=2; continue
            if c=='"': q=None
            out.append(c); last=c
        elif q == "'":
            if c=="'": q=None; last=c
            # content inside single quotes is literal: dropped, never tested
        else:
            if c=='\\':
                # an UNQUOTED backslash consumes the next character: `\'` is literal
                out.append(c); out.append(s[i+1:i+2]); last=c; i+=2; continue
            if c=='"': q='"'; out.append(c); last=c
            elif c=="'": q="'"; last=c
            elif c=='#' and (last is None or last in _WORDSTART):
                break          # a comment: a word BEGINNING with `#`
            else: out.append(c); last=c
        i+=1
    return ''.join(out)
def has_live_backtick(s):
    # ⛔ BACKSLASH PARITY, NOT `(?<!\\)`: one preceding backslash is not "escaped",
    # because the shell consumes them in pairs — `\\\\` before a backtick leaves it
    # executable (measured).
    for m in re.finditer('`', s):
        j=m.start()-1; n=0
        while j >= 0 and s[j]=='\\':
            n+=1; j-=1
        if n % 2 == 0: return True
    return False
out=[]
# ⛔ THE CONTROL COMES FIRST, AND A CRASH IS A HIT — NOT AN EMPTY ANSWER. Without the
#    try/except a missing control fixture or an unreadable target aborts python, and its
#    empty stdout satisfies `assert_eq "$_badbt2" ""` — the sweep passing BECAUSE its
#    machinery failed, which is the same false PASS one level up.
#    A scanner that cannot see line 1 (a false PASS) or that flags lines 2-3 (a false
#    RED) is likewise reported AS A HIT, so the sweep cannot pass by having gone blind —
#    the failure mode the straddling-apostrophe version shipped.
try:
    seen=[i for i,l in enumerate(open(ctrl),1)
          if l.strip() and not l.strip().startswith('#') and has_live_backtick(scan(l.strip()))]
    if seen != [1,4,5,6,7]:
        out.append("SCANNER-SELF-TEST: control hits %r, expected exactly [1, 4, 5, 6, 7] (red: straddled, even-run, mid-word #, quoted-#, escaped-apostrophe; green: single-quoted, one-backslash, escaped-quote-comment)" % (seen,))
    for path in targets:
        for i,l in enumerate(open(path),1):
            st=l.strip()
            if not st or st.startswith('#'): continue
            if has_live_backtick(scan(st)):
                out.append("%s:%d: %s" % (path, i, st[:90]))
except Exception as e:
    out.append("SCANNER-SELF-TEST: the sweep could not run (%r) — an empty answer here is a FAILED sweep, not a clean one" % (e,))
print("\n".join(out))
PY48B
}
_badbt2="$(_badbt2_sweep "$T/btctrl.sh" "$SCRIPT_DIR/record-review.sh" "$SCRIPT_DIR/$(basename "$0")")"
assert_eq "$_badbt2" "" "20h48b no double-quoted string in the recorder OR this suite executes its own backticks (labels included — 20h48 scans only the recorder; the scanner is pinned by its own 8-line control, and a crash is a hit)"
# 20h47 THE THIRD BRANCH IS REACHABLE, AND ITS WORDING IS THE NARROWING ONE (twelfth cycle, P2). A
#       commit that descends from `from` while being neither an ancestor NOR a descendant of the
#       attested head is the one shape a narrowing endpoint can actually take — and no shipped vector
#       reached it (M24's token is skipped by the unrelated-lineage arm), so the third message was
#       dead text. Here it is measured, so a later edit that collapses the three branches reds.
EH55=425246; rm -f "$(Q2 $EH55)"
_b47="$(printf 'sibling\n' | git -C "$DG" hash-object -w --stdin)"
_t47="$(printf '100644 blob %s\tsib.txt\n' "$_b47" | git -C "$DG" mktree)"
DG_SIB="$(git -C "$DG" commit-tree "$_t47" -p "$DG_BASE" -m 'sibling work')"
run_record_delta $EH55 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42524701" \
    STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" \
    STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
I also reviewed up to ${DG_SIB} on the side branch, which is where the real work happened."
assert_eq "$RECORD_RC" "3" "20h47 a commit on a PARALLEL lineage is refused (rc 3)"
assert_contains "$RECORD_ERR" "PARALLEL lineage" "20h47 and the refusal says the lineage it cannot tell apart"
assert_not_contains "$RECORD_ERR" "notation this code does not parse" "20h47 and does NOT assert a narrowing the artifact never wrote (thirteenth cycle)"

# ── 20i — THE DELTA PATH'S REPLACE/GRAFT POSTURE (review of this change, P1) ─────────
# `delta_git` is the ONE line that disables `refs/replace/*` and the grafts FILE for every object
# read the delta arms make (`rev-list`, `merge-tree`, `rev-parse`, `git diff`). It had NO vector
# anywhere: `GIT_NO_REPLACE_OBJECTS` appeared ZERO times in this suite, and
# `tests/record-review/run.sh` (12)/(13) mutate the CARRY walk's `local -x` export — a DIFFERENT
# site — so the pin could be deleted and every vector here stayed green.
#
# WHAT A MISSING PIN BUYS, and why 20h2's fixture cannot show it: the attack needs a merge whose
# tree was HAND-EDITED while its parents still merge CLEANLY. Then `merge-tree` answers rc 0 with
# the AUTOMATIC tree, so a replacement object carrying that tree makes the hand-edited merge
# compare EQUAL to the automatic one — the classifier calls it a clean merge, the range becomes
# merge-only, the cover requirement degrades to "a comment naming A", and `clean` is minted over
# lines nobody reviewed. 20h2's parents CONFLICT, so its `merge-tree` exits 1 and the rc check
# alone refuses; the forgery is unreachable there.
git checkout -q -b hidlane "$DG_A1" >/dev/null 2>&1
printf 'lane h1\n' > h1.txt; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'lane: h1'
DG_HI_L="$(git rev-parse HEAD)"
printf '%s\n' '2025-08-01T00:00:00Z' > "$T/dates/$DG_HI_L"
git checkout -q -b hidbase "$DG_A1" >/dev/null 2>&1
printf 'base h2\n' > h2.txt; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'base: h2'
DG_HI_B="$(git rev-parse HEAD)"
printf '%s\n' '2025-08-01T00:00:00Z' > "$T/dates/$DG_HI_B"
git checkout -q hidlane >/dev/null 2>&1 || true
git -c core.editor=true merge --no-ff --no-commit "$DG_HI_B" >/dev/null 2>&1 || true
# the hand edit lives ONLY in the merge commit — the state a reviewer never saw
printf 'HAND EDIT nobody reviewed\n' >> h1.txt
git add -A
GIT_COMMITTER_DATE='2025-09-01T00:00:00Z' GIT_AUTHOR_DATE='2025-09-01T00:00:00Z' \
    git commit -qm 'merge base (tree hand-edited after a CLEAN merge)'
DG_HI_H="$(git rev-parse HEAD)"
printf '%s\n' '2025-09-01T00:00:00Z' > "$T/dates/$DG_HI_H"
# BOTH premises are ASSERTED, or the vector silently stops testing the arm it was written for.
if [ "$(git rev-list --merges "$DG_HI_L..$DG_HI_H" --not "$DG_HI_B" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
    ok "20i1 fixture: the range's only new MERGE is the merge commit"
else
    bad "20i1 fixture: the range does not hold exactly one merge — the vector would not test the classifier"
fi
# ⛔ THE PREMISE THE VECTOR ACTUALLY NEEDS IS "NO LANE-AUTHORED (NON-MERGE) COMMIT IN THE RANGE", and
#    the merge count above does not measure it (review of this change: the range legitimately also
#    holds the base-side commit, so a LABEL saying "the only new commit is the merge" stayed green
#    while the property it advertises was gone). Asserted separately, on the excluded walk the
#    classifier itself uses.
if [ -z "$(git rev-list --no-merges "$DG_HI_L..$DG_HI_H" --not "$DG_HI_B" 2>/dev/null)" ]; then
    ok "20i1 fixture: NO lane-authored commit is in the range — the merge is the only thing it holds"
else
    bad "20i1 fixture: the range holds a non-merge commit, so it is authored regardless of the driver or the forge — this vector would certify nothing"
fi
DG_HI_PAR="$(git rev-list --parents -n1 "$DG_HI_H" 2>/dev/null)" || DG_HI_PAR=""
read -r _hi_self DG_HI_P1 DG_HI_P2 _hi_rest <<< "$DG_HI_PAR"
_hi_mtrc=0
DG_HI_MT="$(git merge-tree --write-tree "$DG_HI_P1" "$DG_HI_P2" 2>/dev/null)" || _hi_mtrc=$?
DG_HI_MT="${DG_HI_MT%%$'\n'*}"
if [ "$_hi_mtrc" = "0" ]; then
    ok "20i1 fixture: the merge is CLEAN (merge-tree rc 0) — the shape a replace ref can forge"
else
    bad "20i1 fixture: merge-tree exits $_hi_mtrc, so the rc check would refuse on its own and this vector would certify nothing"
fi
if [ -n "$DG_HI_MT" ] && [ "$DG_HI_MT" != "$(git rev-parse "$DG_HI_H^{tree}")" ]; then
    ok "20i1 fixture: the merge tree is NOT the automatic one (the hand edit is real)"
else
    bad "20i1 fixture: the merge tree equals the automatic one — nothing was hand-edited"
fi
# A cover dated BETWEEN the lane work (2025-08-01) and the hand-edited merge (2025-09-01): it
# postdates A, so a recorder that believed a forgery (merge-only ⇒ anchor = A) would ACCEPT it.
EHI1=425150; rm -f "$(Q2 $EHI1)"
run_record_delta $EHI1 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H+comment:42515001" \
    STUB_BASE_SHA="$DG_HI_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i1 a hand-edited merge that postdates the cover is refused (rc 3)"
# ⛔ THE ANCHOR IS THE ATTRIBUTION HERE, not the wording of the no-cover sentence: with a cover
#    named, the refusal is verify_review_evidence's date refusal, and what identifies WHICH commit
#    the classifier anchored on is the sha it prints. A recorder that believed a forged
#    (merge-only) range would anchor on A and ACCEPT; this one anchors on the hand-edited merge.
assert_contains "$RECORD_ERR" "postdates ${DG_HI_H:0:12}" \
    "20i1 the anchor is the hand-edited MERGE — the classifier read the REAL tree, not the forged one"
[ ! -f "$(Q2 $EHI1)" ] && ok "20i1 no record written over the hand edit" || bad "20i1 a clean was minted over the hand edit"
# ⛔ THE FORGERY, PLANTED. The replacement carries the AUTOMATIC tree and the SAME parents, so
# plain git now answers `<merge>^{tree}` with the tree `merge-tree` produces — the tree-equality
# test alone cannot catch it, which is exactly why the export exists.
DG_HI_FAKE="$(git commit-tree "$DG_HI_MT" -p "$DG_HI_P1" -p "$DG_HI_P2" -m 'forged: the automatic merge tree')" || DG_HI_FAKE=""
git replace "$DG_HI_H" "$DG_HI_FAKE" >/dev/null 2>&1 || true
if [ "$(git rev-parse "$DG_HI_H^{tree}")" = "$DG_HI_MT" ]; then
    ok "20i1 control: the replace ref is LIVE — the merge now REPORTS the automatic tree"
else
    bad "20i1 control: the replace ref did not take, so the fixture is vacuous"
fi
if [ "$(GIT_NO_REPLACE_OBJECTS=1 git rev-parse "$DG_HI_H^{tree}")" != "$DG_HI_MT" ]; then
    ok "20i1 control: under GIT_NO_REPLACE_OBJECTS the REAL tree is still visible"
else
    bad "20i1 control: the export is not what makes the difference"
fi
EHI2=425151; rm -f "$(Q2 $EHI2)"
run_record_delta $EHI2 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H+comment:42515101" \
    STUB_BASE_SHA="$DG_HI_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i1 WITH the replace ref planted the SAME range is still REFUSED (rc 3)"
assert_contains "$RECORD_ERR" "postdates ${DG_HI_H:0:12}" \
    "20i1 …and the anchor is STILL the real merge — the pin made the replacement invisible to every arm"
git replace -d "$DG_HI_H" >/dev/null 2>&1 || true
# 20i2 THE GRAFTS FILE is a DIFFERENT mechanism, and `GIT_NO_REPLACE_OBJECTS` does NOT cover it
#      (`tests/record-review/run.sh` (13) records that lesson for the carry walk). Here the graft
#      rewrites the merge's PARENTAGE, so plain git stops seeing a merge at all and walks the
#      commit as ordinary authored content — a classification change a graft-honouring recorder
#      would report as the COUNT form ("contains authored content (1 commit(s))").
printf '%s %s\n' "$DG_HI_H" "$DG_HI_L" > "$DG/.git/info/grafts"
if [ "$(git rev-list --parents -n1 "$DG_HI_H" 2>/dev/null | wc -w | tr -d ' ')" = "2" ]; then
    ok "20i2 control: the grafts file is LIVE — plain git now sees ONE parent (no merge)"
else
    bad "20i2 control: the grafts file did not take, so the fixture is vacuous"
fi
# ⛔ COVER-LESS ON PURPOSE. With a cover both classifications refuse on the same DATE sentence,
#    so the exit code and the message would be identical and the vector would certify nothing.
#    Without one, the two classifications print DIFFERENT sentences: a recorder that sees the
#    MERGE says "holds authored content in a MERGE" (n_authored = 0); one that honoured the graft
#    sees an ordinary authored commit and says "contains authored content (1 commit(s))".
EHI3=425152; rm -f "$(Q2 $EHI3)"
run_record_delta $EHI3 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H" STUB_BASE_SHA="$DG_HI_B"
assert_eq "$RECORD_RC" "3" "20i2 a grafted-away merge is still refused (rc 3)"
assert_contains "$RECORD_ERR" "holds authored content in a MERGE" \
    "20i2 the refusal is STILL the evil-merge arm — GIT_GRAFT_FILE made the graft invisible"
assert_not_contains "$RECORD_ERR" "contains authored content (1 commit(s))" \
    "20i2 …and NOT the count form a graft-honouring recorder would produce"
rm -f "$DG/.git/info/grafts"

# 20i3 THE ORACLE ITSELF — AN AMBIENT ATTRIBUTES FILE (cycle-2/3 review, P1; reported with runnable
#      repros, reproduced here before the fix). `merge-tree` honours merge drivers, and the BUILT-IN
#      ones (`union`) have NO config key at all — so `merge=union` named from an attributes file
#      steers the oracle with nothing but a `printf`. Measured in this fixture: the conflict answers
#      rc 1 with no attributes and rc 0 returning EXACTLY the hand "keep both" tree once the file
#      exists. The attribute source that matters is the one the DIFF cannot see: an UNTRACKED (or
#      modified) `.gitattributes` in the worktree, and `.git/info/attributes`. A `.gitattributes`
#      committed in the merge's own tree is a legitimate repo semantic (tortoise#5373) and stays
#      accepted.
git checkout -q -b uni_lane "$DG_A1" >/dev/null 2>&1 || true
printf 'lane-line\n' > u.txt; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'lane: u'
DG_UN_L="$(git rev-parse HEAD)"
printf '%s\n' '2025-08-01T00:00:00Z' > "$T/dates/$DG_UN_L"
git checkout -q -b uni_base "$DG_A1" >/dev/null 2>&1 || true
printf 'base-line\n' > u.txt; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'base: u'
DG_UN_B="$(git rev-parse HEAD)"
printf '%s\n' '2025-08-01T00:00:00Z' > "$T/dates/$DG_UN_B"
git checkout -q uni_lane >/dev/null 2>&1 || true
git -c core.editor=true merge --no-ff --no-commit "$DG_UN_B" >/dev/null 2>&1 || true
# the hand resolution is the ordinary "keep both" concatenation — i.e. exactly `merge=union`'s output
printf 'lane-line\nbase-line\n' > u.txt
git add -A
GIT_COMMITTER_DATE='2025-09-01T00:00:00Z' GIT_AUTHOR_DATE='2025-09-01T00:00:00Z' \
    git commit -qm 'keep both (hand resolution)'
DG_UN_H="$(git rev-parse HEAD)"
printf '%s\n' '2025-09-01T00:00:00Z' > "$T/dates/$DG_UN_H"
_un_mt=0
DG_UN_MT="$(git merge-tree --write-tree "$DG_UN_L" "$DG_UN_B" 2>/dev/null)" || _un_mt=$?
DG_UN_MT="${DG_UN_MT%%$'\n'*}"
if [ "$_un_mt" != "0" ] && [ "$DG_UN_MT" != "$(git rev-parse "$DG_UN_H^{tree}")" ]; then
    ok "20i3 fixture: WITHOUT the attribute the merge CONFLICTS (rc $_un_mt) and its tree is not the hand one"
else
    bad "20i3 fixture: the conflict premise does not hold (rc=$_un_mt) — the vector would certify nothing"
fi
printf 'u.txt merge=union\n' > .gitattributes
_un_mt2=0
DG_UN_MT2="$(git merge-tree --write-tree "$DG_UN_L" "$DG_UN_B" 2>/dev/null)" || _un_mt2=$?
DG_UN_MT2="${DG_UN_MT2%%$'\n'*}"
if [ "$_un_mt2" = "0" ] && [ "$DG_UN_MT2" = "$(git rev-parse "$DG_UN_H^{tree}")" ]; then
    ok "20i3 control: the UNTRACKED attribute STEERS the oracle — rc 0, tree EQUAL to the hand resolution"
else
    bad "20i3 control: the ambient attribute did not steer merge-tree (rc=$_un_mt2), so this vector does not reproduce the bypass"
fi
# a cover that POSTDATES A: for a merge-only range that is sufficient, so the ambient attribute is
# the only thing between this input and a minted `clean`.
EHI7=425156; rm -f "$(Q2 $EHI7)"
run_record_delta $EHI7 "$DG_UN_H" "delta:$DG_UN_L..$DG_UN_H+comment:42515601" \
    STUB_BASE_SHA="$DG_UN_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i3 an AMBIENT .gitattributes is refused (rc 3)"
assert_contains "$RECORD_ERR" "AMBIENT ATTRIBUTES file steers" "20i3 the refusal names the ambient attribute source"
assert_contains "$RECORD_ERR" ".gitattributes" "20i3 …and names the file it found"
[ ! -f "$(Q2 $EHI7)" ] && ok "20i3 no record written" || bad "20i3 a clean was minted from a steered oracle"
# ⛔ THE ATTRIBUTION IS THE MUTATION CELL (M36), NOT AN IN-VECTOR CONTROL: with the attribute removed
#    this merge CONFLICTS again, so the range is EVIL and refuses on the anchor regardless of the
#    refusal under test — a "control" here would refuse for a different reason and certify nothing.
#    The premise that the attribute really steers the oracle is asserted with git itself, above.
rm -f .gitattributes
# 20i6 THE BOX-GLOBAL SOURCES — `core.attributesFile` and the default `$XDG_CONFIG_HOME/git/attributes`
#      are MACHINE settings, so the oracle read neutralises them instead of refusing (cycle-4
#      review, P1: `~/.config/git/attributes` steering `merge=union` produced rc 0 + tree-equal while
#      every ambient scan came back empty). The recorder's HOME here is the suite's FAKE home, which
#      is exactly where a user-level attribute file lives.
#    ⛔ `XDG_CONFIG_HOME=` ON THE VECTOR BELOW IS PART OF ITS PREMISE, NOT TIDINESS — the same
#    measured class as M38. git resolves the DEFAULT user-level attributes file as
#    `$XDG_CONFIG_HOME/git/attributes` when that variable holds a NON-EMPTY value, and falls back to
#    `$HOME/.config/git/attributes` when it is unset OR EMPTY — which is why the pin is spelled
#    `XDG_CONFIG_HOME=` (empty) and NOT `env -u XDG_CONFIG_HOME`: an empty value still falls back. A
#    runner exports it (`worker-terminal.test.sh:36`), so with an inherited NON-EMPTY value the
#    fixture is written where no git process looks and this vector silently degenerates into a
#    duplicate of 20i3's plain-conflict case. ⛔ `origin/main` ALSO pins it SUITE-WIDE —
#    `export XDG_CONFIG_HOME="$F_HOME/.config"` (#3755), which this branch's older base predates —
#    so this per-vector pin is belt-and-braces: it keeps the vector independent of that suite-level
#    line rather than being the only thing carrying the fix. The control on the next line has always
#    pinned it; the vector did not.
mkdir -p "$F_HOME/.config/git"
printf 'u.txt merge=union\n' > "$F_HOME/.config/git/attributes"
_un_g=0
DG_UN_MT3="$(HOME="$F_HOME" XDG_CONFIG_HOME= git merge-tree --write-tree "$DG_UN_L" "$DG_UN_B" 2>/dev/null)" || _un_g=$?
DG_UN_MT3="${DG_UN_MT3%%$'\n'*}"
if [ "$_un_g" = "0" ] && [ "$DG_UN_MT3" = "$(git rev-parse "$DG_UN_H^{tree}")" ]; then
    ok "20i6 control: a GLOBAL attributes file really steers plain merge-tree (rc 0, tree = the hand resolution)"
else
    bad "20i6 control: the global attributes file did not steer merge-tree (rc=$_un_g), so this vector certifies nothing"
fi
EHIA=425160; rm -f "$(Q2 $EHIA)"
run_record_delta $EHIA "$DG_UN_H" "delta:$DG_UN_L..$DG_UN_H+comment:42516001" \
    XDG_CONFIG_HOME= STUB_BASE_SHA="$DG_UN_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i6 a GLOBAL attributes file does NOT steer the recorder's oracle (rc 3)"
# ⛔ THE ANCHOR IS THE ATTRIBUTION when a cover is named (the no-cover sentence belongs to the other
#    branch): a recorder whose oracle HAD been steered would classify merge-only, anchor on A and
#    ACCEPT. This one still anchors on the hand merge, which is only possible if it saw the conflict.
assert_contains "$RECORD_ERR" "postdates ${DG_UN_H:0:12}" \
    "20i6 …the hand resolution is still classified EVIL (the anchor is the merge), because the oracle read neutralised the machine's rule"
rm -f "$F_HOME/.config/git/attributes"
# 20i7 THE TRACKED-BUT-DRIFTED `.gitattributes` (cycle-5 review, P0 — the previous commit dropped
#      `-m` while adding `-o`, which LOST the modified-tracked case it had been catching; the staged
#      and skip-worktree shapes were never in the population at all). The property is not an index
#      state: it is whether the file the ORACLE reads differs from the one in the MERGE'S OWN TREE.
#      All three states below steer `merge-tree` into the hand resolution and are invisible to
#      `ls-files -o`; the drift read (`git diff <merge> -- <pathspec>`) is what catches the first
#      two, and the flag scan catches the third because git refuses to compare it at all.
git checkout -q -b attr_base "$DG_A1" >/dev/null 2>&1 || true
printf '# fixture, no merge rules\n' > .gitattributes; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'fixture: tracked gitattributes'
printf 'base-w\n' > w.txt; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'base: w'
DG_AT_B="$(git rev-parse HEAD)"
printf '%s\n' '2025-08-01T00:00:00Z' > "$T/dates/$DG_AT_B"
git checkout -q -b attr_lane "$DG_A1" >/dev/null 2>&1 || true
printf 'lane-w\n' > w.txt; git add -A
GIT_COMMITTER_DATE='2025-08-01T00:00:00Z' GIT_AUTHOR_DATE='2025-08-01T00:00:00Z' git commit -qm 'lane: w'
DG_AT_L="$(git rev-parse HEAD)"
printf '%s\n' '2025-08-01T00:00:00Z' > "$T/dates/$DG_AT_L"
git -c core.editor=true merge --no-ff --no-commit "$DG_AT_B" >/dev/null 2>&1 || true
printf 'lane-w\nbase-w\n' > w.txt; git add -A
GIT_COMMITTER_DATE='2025-09-01T00:00:00Z' GIT_AUTHOR_DATE='2025-09-01T00:00:00Z' git commit -qm 'keep both (hand)'
DG_AT_H="$(git rev-parse HEAD)"
printf '%s\n' '2025-09-01T00:00:00Z' > "$T/dates/$DG_AT_H"
_at_mt=0
DG_AT_MT="$(git merge-tree --write-tree "$DG_AT_L" "$DG_AT_B" 2>/dev/null)" || _at_mt=$?
DG_AT_MT="${DG_AT_MT%%$'\n'*}"
if [ "$_at_mt" != "0" ] && [ "$DG_AT_MT" != "$(git rev-parse "$DG_AT_H^{tree}")" ]; then
    ok "20i7 fixture: the merge CONFLICTS while .gitattributes is untouched (rc $_at_mt)"
else
    bad "20i7 fixture: the conflict premise does not hold (rc=$_at_mt)"
fi
# the DRIFTED worktree copy: TRACKED, modified, NOT untracked, NOT staged
printf 'w.txt merge=union\n' > .gitattributes
_at_mt2=0
DG_AT_MT2="$(git merge-tree --write-tree "$DG_AT_L" "$DG_AT_B" 2>/dev/null)" || _at_mt2=$?
DG_AT_MT2="${DG_AT_MT2%%$'\n'*}"
if [ "$_at_mt2" = "0" ] && [ "$DG_AT_MT2" = "$(git rev-parse "$DG_AT_H^{tree}")" ]; then
    ok "20i7 control: the DRIFTED tracked attribute steers the oracle (rc 0, tree = the hand resolution)"
else
    bad "20i7 control: the drifted attribute did not steer merge-tree (rc=$_at_mt2)"
fi
if [ -z "$(git ls-files -o 2>/dev/null)" ]; then
    ok "20i7 control: the drifted file is NOT untracked — ls-files -o sees nothing, which is why drift is a separate read"
else
    bad "20i7 control: the fixture file is untracked, so this vector would test the wrong arm"
fi
EHIB=425161; rm -f "$(Q2 $EHIB)"
run_record_delta $EHIB "$DG_AT_H" "delta:$DG_AT_L..$DG_AT_H+comment:42516101" \
    STUB_BASE_SHA="$DG_AT_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i7 a MODIFIED tracked .gitattributes is refused (rc 3)"
assert_contains "$RECORD_ERR" "worktree copy differs from merge" "20i7 the refusal names the drift, not an index state"
# STAGED: same content, now in the index — invisible to `-o` and to `-m`
git add .gitattributes
EHIBA=425162; rm -f "$(Q2 $EHIBA)"
run_record_delta $EHIBA "$DG_AT_H" "delta:$DG_AT_L..$DG_AT_H+comment:42516201" \
    STUB_BASE_SHA="$DG_AT_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i7 a STAGED tracked .gitattributes is refused (rc 3)"
# SKIP-WORKTREE: git refuses to compare the file, so equality cannot be proven
git update-index --skip-worktree .gitattributes
EHIBB=425163; rm -f "$(Q2 $EHIBB)"
run_record_delta $EHIBB "$DG_AT_H" "delta:$DG_AT_L..$DG_AT_H+comment:42516301" \
    STUB_BASE_SHA="$DG_AT_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i7 a SKIP-WORKTREE .gitattributes is refused (rc 3)"
git update-index --no-skip-worktree .gitattributes 2>/dev/null || true
# ⛔ UNSTAGE IT TOO. `git add` above left the union content in the INDEX; leaving it there makes the
#    later `rm -f .gitattributes` a worktree DELETION relative to the index, which the drift read
#    reports — so every following cell would refuse for a fixture residue rather than its own reason
#    (measured: M36 "mutant still refused").
git reset -q -- .gitattributes 2>/dev/null || true
git checkout -- .gitattributes 2>/dev/null || true
# ⛔ LEAVE THE FIXTURE REPO ON A BRANCH THAT HAS NO TRACKED .gitattributes. Later cells (M36) write
#    an UNTRACKED one to test the untracked arm; with a tracked file still in the checkout that write
#    would become a MODIFICATION, the drift arm would fire instead, and those cells would go vacuous
#    (measured: M36 "mutant still refused"). 20i1's `hidlane` is that branch.
git checkout -q hidlane >/dev/null 2>&1 || true
rm -f .gitattributes
# 20i5 THE CONFIG HALF: a CUSTOM driver (which has a config key) steered from an untracked
#      attribute. Both halves are needed — the built-in drivers have no key, and a custom driver
#      needs both the key and the attribute — and the refusal must name the scope, because the key
#      may live in GLOBAL or SYSTEM config where 'record from a pristine checkout' does not help.
printf 'u.txt merge=hidrv\n' > .gitattributes
git config merge.hidrv.driver true || true
EHI9=425158; rm -f "$(Q2 $EHI9)"
run_record_delta $EHI9 "$DG_UN_H" "delta:$DG_UN_L..$DG_UN_H+comment:42515801" \
    STUB_BASE_SHA="$DG_UN_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
assert_eq "$RECORD_RC" "3" "20i5 a CUSTOM merge driver declared in config is refused (rc 3)"
assert_contains "$RECORD_ERR" "DECLARES A MERGE DRIVER" "20i5 the refusal names the config driver"
assert_contains "$RECORD_ERR" "merge.hidrv.driver" "20i5 …and names the offending config key"
assert_contains "$RECORD_ERR" "scope" "20i5 …and says the key may live in GLOBAL or SYSTEM scope (the remedy depends on it)"
[ ! -f "$(Q2 $EHI9)" ] && ok "20i5 no record written" || bad "20i5 a clean was minted from a custom-driver-steered oracle"
rm -f .gitattributes
git config --unset merge.hidrv.driver 2>/dev/null || true
# 20i4 THE TOKEN SCAN'S FAILURE ARM (cycle-2 review, P2). `grep` exits 1 for a legitimate
#      no-match, but a REAL failure of any pipeline member used to produce the same empty list, so
#      the population loop silently did not execute. A shim is the only way to reach that state:
#      `command sort` still resolves through PATH, and `$T/bin` is prepended for the recorder.
# ⛔ THE SHIM MUST FAIL ONLY THE SCAN'S OWN CALL. A blanket `sort` failure also breaks the
#    recorder's other `sort` uses (the anchor's `sort -rn`), so the run refused on an unrelated
#    arm and the vector certified nothing (measured: rc 3 without the scan's sentence). `sort -u`
#    is what the token scan pipes into; anything else is delegated to the real binary.
printf '#!/bin/sh\nif [ "$1" = "-u" ]; then exit 2; fi\nexec /usr/bin/sort "$@"\n' > "$T/bin/sort"; chmod +x "$T/bin/sort"
EHI6=425155; rm -f "$(Q2 $EHI6)"
run_record_delta $EHI6 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H+comment:42515501" \
    STUB_BASE_SHA="$DG_HI_B" STUB_EVIDENCE_AT="2026-01-01T00:00:00Z"
rm -f "$T/bin/sort"
assert_eq "$RECORD_RC" "3" "20i4 a token scan that COULD NOT RUN is refused (rc 3)"
assert_contains "$RECORD_ERR" "the commit-token scan FAILED" \
    "20i4 …and the refusal says the SCAN failed, instead of reading as a claim about the claim"
[ ! -f "$(Q2 $EHI6)" ] && ok "20i4 no record written" || bad "20i4 a scan that never ran still minted a clean"

# ── 20g — MUTATION MATRIX: break each guard, name the vector that goes RED ──
# ⛔ errexit is OFF for this block on purpose. A mutation harness that ABORTS the
# whole suite when an anchor text moves is a footgun: an unrelated edit renames
# `if [ ! -s "$tmp" ]` and the entire run dies instead of reporting "this vector
# was not measured". With errexit off, a mutant that cannot be built is a NAMED
# failure in mut_check, and the run still reaches its summary.
set +e
# Every mutant is a scratch copy of the recorder (with its lib/ sibling, because
# DIFF_NORMALIZER resolves against the SCRIPT's own directory). If a mutant still
# refuses, the vector it targets was NOT testing that guard.
mk_mutant() { # <name> <python-old> <python-new> -> $T/mut-<name>/record-review.sh
    local name="$1" old="$2" new="$3"
    local d="$T/mut-$name"
    mkdir -p "$d/lib"; cp "$SCRIPT_DIR/lib/diff-normalize.py" "$d/lib/diff-normalize.py"
    python3 - "$RECORD" "$d/record-review.sh" "$old" "$new" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read()
assert old in text, "mutation anchor not found: %r" % old[:60]
open(dst, "w").write(text.replace(old, new, 1))
PY
    [ -s "$d/record-review.sh" ] || return 1
    # ⛔ A MUTANT THAT DOES NOT PARSE MUST NOT SCORE OK (found in review). `mut_check … refused`
    # accepts ANY non-zero exit, and bash exits 2 on a syntax error — so a mutation whose
    # replacement broke the file's syntax would have reported "the guard is load-bearing" from a
    # script that never ran a single arm. A parse check is the cheapest way to close that for
    # EVERY cell at once rather than relying on each one's message attribution.
    bash -n "$d/record-review.sh" 2>/dev/null || return 1
    printf '%s' "$d/record-review.sh"
}
mut_run() { # <mutant-script> <pr> <sha> <ref> [VAR=VAL…] → $RECORD_RC
    local mut="$1" pr="$2" sha="$3" ref="$4"; shift 4
    local kv
    (
        export HOME="$F_HOME" PATH="$T/bin:$PATH" GH_STUB_LOG="$LOG" DELTA_GIT_DIR="$DG"
        export STUB_EVIDENCE_PR="$pr" STUB_EVIDENCE_REPO="daniel-ospina/agent-infra" STUB_HEAD_SHA="$sha"
        export STUB_BASE_PAIR=1 STUB_BASE_SHA="$DG_M1" STUB_BASE_REF=main STUB_COMMIT_DATES_DIR="$T/dates"
        export STUB_EVIDENCE_BODY="reviewed ${ref%%+*}; no issues found."
        for kv in "$@"; do export "$kv"; done
        # ⛔ THE MUTATION HARNESS MINTS A FRESH `clean` TOO, so it owes the same #3442 block
        # (`verify_review_evidence`'s non-vacuity arm) — without it every mutant refused at 3
        # from a DIFFERENT guard than the one it mutates, which is the exact vacuity this
        # matrix exists to detect, reported against itself. Applied after the overrides, on
        # the same terms as `run_record_delta` (a vector may opt out with
        # DELTA_NO_VACUITY_BLOCK=1), so the body each vector wrote up to the blank line is
        # what the range-scanning arms below actually see.
        if [ "${DELTA_NO_VACUITY_BLOCK:-0}" != 1 ]; then
            case "$STUB_EVIDENCE_BODY" in
                *"MUTATION ATTRIBUTION"*) : ;;
                *) STUB_EVIDENCE_BODY="$STUB_EVIDENCE_BODY

$VACUITY_BLOCK"; export STUB_EVIDENCE_BODY ;;
            esac
        fi
        rc=0
        bash "$mut" "$pr" "$sha" clean "daniel-ospina/agent-infra" --evidence "$ref" >/dev/null 2>"$T/merr" || rc=$?
        printf '%s' "$rc" > "$T/mrc"
    ) 2>/dev/null
    RECORD_RC="$(cat "$T/mrc" 2>/dev/null || echo 99)"
}
MM=0; MM_OK=0
mut_check() { # <label> <pr> <sha> <ref> <expect: accepted|refused|accepted-constant> [VAR=VAL…]
    MM=$((MM+1))
    local label="$1" pr="$2" sha="$3" ref="$4" expect="$5"; shift 5
    if [ ! -s "${MUT:-}" ]; then
        bad "20g $label: the mutant could not be built (mutation anchor missing from the recorder) — this vector was NOT measured"
        return 0
    fi
    rm -f "$(Q2 $pr)"
    mut_run "$MUT" "$pr" "$sha" "$ref" "$@"
    if [ "$expect" = "accepted" ] || [ "$expect" = "accepted-constant" ]; then
        if [ "$RECORD_RC" = "0" ]; then MM_OK=$((MM_OK+1)); ok "20g $label: guard removed → ACCEPTED (rc 0), so the shipped vector is load-bearing"
        else bad "20g $label: mutant still refused (rc=$RECORD_RC) — the vector is vacuous"; fi
        if [ "$expect" = "accepted-constant" ]; then
            local md
            md="$(sed -n 's/.*"delta_digest":"\([0-9a-f]*\)".*/\1/p' "$(Q2 $pr)" 2>/dev/null | head -1)"
            assert_eq "$md" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
                "20g $label: the mutant minted the sha256-of-EMPTY constant (one digest for every empty range)"
        fi
    else
        if [ "$RECORD_RC" != "0" ]; then MM_OK=$((MM_OK+1)); ok "20g $label: guard broken → REFUSED (rc=$RECORD_RC), so the acceptance vector is load-bearing"
        else bad "20g $label: mutant still accepted — the vector is vacuous"; fi
    fi
}
mk_mutant2() { # <mutant-path> <old> <new> — a SECOND replacement in a mutant copy
    python3 - "$1" "$2" "$3" <<'PY2'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(p).read()
assert old in text, "second mutation anchor not found: %r" % old[:60]
open(p, "w").write(text.replace(old, new, 1))
PY2
}
# M1 — the EMPTY-DIFF guard TOGETHER WITH the normalizer-output guard. Disabling
# both mints a delta over NOTHING carrying the sha256-of-EMPTY CONSTANT — the
# #1362 constant-collision shape, where ONE digest matches every empty range.
# (Alone, either arm still refuses, which is why M1b measures that redundancy.)
MUT="$(mk_mutant emptyconstant '  if [ ! -s "$tmp" ]; then' '  if false; then')"
mk_mutant2 "$MUT" '"$norm" 2>/dev/null || [ ! -s "$norm" ]; then' '"$norm" 2>/dev/null; then'
mut_check "M1 empty-diff + normalizer-output arms" 425120 "$DG_EMPTY" "delta:$DG_NEW..$DG_EMPTY+comment:42512001" accepted-constant
# M1b — the REDUNDANCY measurement: with ONLY the A==B arm removed, the A==B
# vector must STILL be refused (the empty-diff arm catches it). If this ever turns
# red, the A==B arm became load-bearing and M1 must be re-targeted.
MUT="$(mk_mutant emptyrange '  if [ "$from" = "$to" ]; then' '  if false; then')"
mut_check "M1b empty-range arm is covered by the empty-diff arm" 425126 "$DG_HEAD" "delta:$DG_HEAD..$DG_HEAD" refused
# M2 — the ancestry guard. The vector must ALSO satisfy every later arm, or the
# mutant refuses for a different reason and the cell certifies nothing: DG_HEAD..
# DG_A1 is AUTHORED (DG_A1 is the lane's own commit), so it carries a covering
# verdict that postdates it.
MUT="$(mk_mutant ancestry '  delta_git "$root" merge-base --is-ancestor "$from" "$to" 2>/dev/null || dg_rc=$?' '  dg_rc=0')"
mut_check "M2 ancestry guard" 425121 "$DG_A1" "delta:$DG_HEAD..$DG_A1+comment:42512101" accepted
# M3 — B == the recorded head. ⛔ THE VECTOR MUST BE 20c1'S (record at A, range
# ending at the head): the first version of this cell recorded at the head AND
# ended the range there, so the mutated guard was never reached and the cell
# passed for BOTH the shipped and the mutant script — a vacuous cell that
# certified nothing (found in review of this change).
MUT="$(mk_mutant upperbound '  if [ "$to" != "$head" ]; then' '  if false; then')"
# the merge-only premise must ALSO hold, or the mutant refuses for that reason
# instead (the same vacuity trap, one arm down). mut_check clears the record
# before running, so a planted prior record cannot serve here — a covering
# verdict can.
mut_check "M3 range-upper-bound guard" 425122 "$DG_A1" "delta:$DG_A1..$DG_HEAD+comment:42512201" accepted
# M4 — authored ranges need a covering verdict.
MUT="$(mk_mutant cover '    if [ -z "$cover" ]; then' '    if false; then')"
mut_check "M4 authored-needs-cover" 425123 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD" accepted
# M5 — the covering verdict's ANCHOR is the newest authored commit.
MUT="$(mk_mutant anchor '    anchor="$newest"' '    anchor="$to"')"
mut_check "M5 covering-verdict anchor" 425124 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42512401" accepted STUB_EVIDENCE_AT="2025-01-01T00:00:00Z"
# M6 — the base-aware classification (the reverse direction: breaking it must
#      REFUSE the merge-only acceptance vector, or 20a tests nothing).
# ⛔ THE VECTOR MUST BE 20a'S, COVER INCLUDED (agent-infra#3475). The first version dispatched
#      `delta:$DG_A1..$DG_HEAD` with NO `+comment:`, and BOTH scripts refused it on DIFFERENT
#      arms — the mutant on the authored-needs-cover arm (it classified the range authored) and
#      the shipped code on the merge-only-needs-cover arm — so `mut_check … refused` scored OK
#      for both and certified nothing about the classifier it names. Dispatching 20a's covered
#      vector makes the CLASSIFICATION the only thing the mutant changes: shipped accepts it as
#      merge-only, the mutant calls it authored, moves the anchor past the cover and refuses.
#      The bare vector is kept as the SECOND cell, so the cover-less path is still measured.
MUT="$(mk_mutant baseaware 'rev-list --no-merges "$from..$to" --not "$base_sha"' 'rev-list --no-merges "$from..$to"')"
mut_check "M6 base-aware classification" 425125 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42512501" refused STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" STUB_EVIDENCE_BODY="reviewed $DG_A1; no issues found."
# ⛔ ATTRIBUTION, NOT JUST AN EXIT CODE (agent-infra#3475). `mut_check … refused` accepts ANY
#    non-zero exit, so the cell above is green even if the mutant refused on an arm it does not
#    mutate. Two assertions make the refusal attributable to the CLASSIFIER: the shipped recorder
#    must ACCEPT the very same vector, and the mutant's stderr must be the authored classification.
rm -f "$(Q2 425125)"
run_record_delta 425125 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42512501" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" STUB_EVIDENCE_BODY="reviewed $DG_A1; no issues found."
assert_eq "$RECORD_RC" "0" "20g M6 the SHIPPED recorder ACCEPTS the same covered vector (rc 0) — so the mutant's refusal is caused by the classifier, not by the cover"
assert_contains "$(cat "$T/merr" 2>/dev/null || true)" "authored content" \
    "20g M6 the mutant refused BECAUSE it classified the range as AUTHORED — the arm it mutates — and not on a downstream arm"
mut_check "M6b base-aware classification (cover-less path)" 425125 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD" refused
# ⛔ M6b IS ATTRIBUTABLE, NOT MERELY GREEN (agent-infra#3475). Dispatched cover-less, BOTH
#    scripts refuse — the shipped one on the MERGE-ONLY-needs-cover arm and the mutant on the
#    AUTHORED-needs-cover arm — so `refused` alone would score OK for both and the cell would be
#    the same vacuous shape it was added to retire. The two assertions below DISTINGUISH the arms:
#    the shipped refusal must name "holds no lane-authored commit" (merge-only) and the mutant's
#    must name "contains authored content" (authored). A regression of the classifier moves the
#    mutant's refusal to the merge-only sentence and reds this cell.
rm -f "$(Q2 425125)"
run_record_delta 425125 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD"
assert_eq "$RECORD_RC" "3" "20g M6b the SHIPPED recorder refuses the cover-less vector"
assert_contains "$RECORD_ERR" "holds no lane-authored commit" \
    "20g M6b the shipped refusal is the MERGE-ONLY arm — so the mutant's authored refusal is a DIFFERENT arm, not the same rc 3 twice"
assert_contains "$(cat "$T/merr" 2>/dev/null || true)" "contains authored content" \
    "20g M6b the mutant refused at the AUTHORED arm — the classification the cell names is the thing that changed"
# M7 — the EVIL MERGE in the anchor candidate set. 20h5's cover predates the
#      hand-resolved merge, so dropping the merges from `cands` must ACCEPT it.
MUT="$(mk_mutant evilanchor '    if [ -n "$evil_shas" ]; then' '    if false; then')"
mut_check "M7 evil merge in the anchor set" 425140 "$DG_EV2_HEAD" "delta:$DG_EV_L..$DG_EV2_HEAD+comment:42514001" accepted STUB_EVIDENCE_AT="2026-01-01T00:00:00Z"
# M13 — THE MERGE-TREE EXIT STATUS. `merge-tree --write-tree` PRINTS A TREE ON CONFLICT (exit
#       1), so a hand resolution that reproduces that tree defeats a tree comparison
#       completely. Dropping the status term classifies the conflicted merge as CLEAN, the
#       range as merge-only, and mints `clean` over conflict lines nobody reviewed. This cell
#       was UNMEASURED for four cycles because its own fixture's range was EMPTY — the vector
#       stopped at the EMPTY-DIFF arm further down and never reached this classification. The
#       20h13 fixture now adds one unrelated base-side file (and asserts the diff is
#       NON-EMPTY, without which the vector stops at the EMPTY-DIFF arm and measures nothing).
#       M13's vector therefore carries a COVER, which the merge-only arm requires (it has no
#       local-record shortcut) and dates it BETWEEN A and the merge: the shipped code anchors
#       the cover on B (authored) and refuses a verdict that predates the hand resolution,
#       while the mutant anchors on A (merge-only) and accepts it.
MUT="$(mk_mutant mrcstatus '[ "$mrc" -ne 0 ] || [ -z "$want" ] ||' '[ -z "$want" ] ||')"
mut_check "M13 the merge-tree EXIT STATUS is load-bearing" 425161 "$DG_MDB" "delta:$DG_MDA..$DG_MDB+comment:42516101" accepted STUB_EVIDENCE_AT="2025-05-04T00:00:00Z" STUB_BASE_PAIR=1 STUB_BASE_SHA="$DG_MDM" STUB_BASE_REF=main
# M14b — THE RANGE CONTAINMENT IS NOW REDUNDANT, and this cell measures that instead of
#        pretending otherwise (the M1b precedent). The sixth cycle added the token rule (20h30),
#        which refuses ANY resolvable commit in the claim that is not the head or an ancestor of
#        the range start — so removing the ancestry test from the parsed-range arm no longer
#        opens the vector it used to: the same body is refused one layer down. Reported as
#        REFUSED, which for a mutation cell means "the shipped vector is still refused with this
#        guard gone" — i.e. the guard is defence in depth, not the sole decider. That is worth
#        knowing and is exactly what the first version of this matrix got wrong in the other
#        direction (a cell that claimed coverage it did not have).
MUT="$(mk_mutant rangecontain '          delta_git "$root" merge-base --is-ancestor "$_sfs" "$from" 2>/dev/null || _r=$?' '          _r=0')"
mut_check "M14b range containment is REDUNDANT behind the token rule" 425166 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42516701" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:$DG_A1..$DG_HEAD only; no issues found."
# M15 — THE SEPARATOR TOLERANCE, RE-TARGETED BY THE FIFTH CYCLE. This cell used to mutate the
#       separator AND the refuse-on-unparseable arm so a three-dot body fell through to the
#       bare needle. That fallback is GONE (20h25), so the same three-dot body is refused either
#       way and the cell went vacuous — reported honestly as "mutant still refused". The
#       tolerance still decides something, but only in the ACCEPTANCE direction: an honest
#       reviewer writing `BASE...HEAD` must not be falsely blocked. So the vector is now 20h28
#       (the CORRECT range, three-dot) and the mutant must REFUSE it.
MUT="$(mk_mutant sepdots '(\.{2,3})' '(\.\.)')"
mut_check "M15 a three-dot statement of the CORRECT range is accepted" 425200 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520101" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}...${DG_HEAD}; no issues found."
# M16 (the refuse-on-unparseable arm) and M17 (the token's case/padding) are RETIRED WITH THEIR
# ARM, on the M8 precedent: the fifth cycle made a stated range REQUIRED for an authored range
# (20h25), so a body the matcher cannot parse refuses whether or not the token layer fired. The
# `_delta_tok` predicate now selects only WHICH message is printed — a verdict-neutral detail that
# no mutant can turn into a bypass, and a cell that mutates it can only ever report vacuity. The
# two vectors those cells guarded, 20h19 and 20h20, still assert their refusals; they are "pinned
# by refusal vectors only, not by a mutant", which the matrix summary line already names.
# M18 — THE SHAPE ARM (20h23), RE-TARGETED BY THE FIFTH CYCLE to the direction that still decides.
#       With the bare needle gone, keying on the WORD no longer admits a bypass — it FALSE-BLOCKS
#       an artifact that states the correct range in ordinary prose. So the vector is 20h29 and
#       the mutant must REFUSE it. Written as an `if` because the recorder runs under
#       `set -euo pipefail` — the terse `[ … ] && _scan=…` form returns 1 when no token is present
#       and would abort the mutant instead of reaching the fall-through it is meant to demonstrate.
MUT="$(mk_mutant wordkeyed '_scan="$_claim"; _any=0; _all_ok=1' '_scan=""; if [ "$_delta_tok" -eq 1 ]; then _scan="$_claim"; fi; _any=0; _all_ok=1')"
mut_check "M18 the arm keys on the RANGE SHAPE, not the word" 425202 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520301" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="Reviewed only ${DG_BASE}..${DG_HEAD}; no issues found."
# M19 — THE EXHAUSTIVE SCAN (20h24). Stopping after the FIRST match is the leftmost-match
#       behaviour the fourth cycle found: the recorded range satisfies every clause, so the
#       narrower range the artifact actually read is never examined and the record asserts a
#       range over commits nobody reviewed.
# M19b — THE EXHAUSTIVE SCAN IS NOW REDUNDANT for narrow-range detection, on the same terms as
#        M14b: the token rule refuses the narrowed range wherever it appears in the claim, so
#        stopping after the first match no longer re-accepts the vector. Reported as REFUSED.
MUT="$(mk_mutant firstonly '      _scan="${_scan#*"${BASH_REMATCH[0]}"}"' '      _scan=""')"
mut_check "M19b the exhaustive scan is REDUNDANT behind the token rule" 425192 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519301" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="delta:${DG_BASE}..${DG_HEAD} is the brief; I read delta:${DG_A1}...${DG_HEAD} only; no issues found."
# M10 — the ANCHOR POPULATION. Re-inserting the `break` on the first non-clean
#       merge truncates `evil_shas` to the backdated CHILD, so 20h9's cover (which
#       predates the parent's hand-resolution) is accepted again: the same class as
#       the inert-anchor bug, one level down — the variable was right, the
#       population was truncated.
MUT="$(mk_mutant breakanchor '      : "${evil:=merge ${m:0:12} is NOT a clean merge' '      break; : "${evil:=merge ${m:0:12} is NOT a clean merge')"
mut_check "M10 chained evil merges all reach the anchor" 425152 "$EM_CHILD" "delta:$DG_EV_L..$EM_CHILD+comment:42515002" accepted STUB_EVIDENCE_AT="2026-05-01T00:00:00Z"
# M11 — THE CLAUSE-(E) POLARITY. An UNNAMED answer from the check-surface predicate must
#       refuse. (#3440) DELETED the `target_head_red` wrapper this cell used to mutate, so
#       the anchor now targets the LIVE predicate — `check_surface_scan`, called directly by
#       the delta arm — and injects an answer the `case` does not name (`weird_answer`).
#       The shipped code refuses it, and a version whose case names only the known-bad
#       values and lets everything else fall through as "not red" ACCEPTED it and minted
#       `clean` over a head whose checks were never shown non-red — the enum fall-through
#       the AGENTS.md verification-state rule forbids. The mutant is the SIMULATION of that
#       drift, so this cell asserts REFUSED: it reddens precisely when the polarity
#       regresses. ⛔ Cite the live predicate, never a name that no longer exists in
#       record-review.sh (the same rule 14.14d states).
MUT="$(mk_mutant unnamedcheck '  E_OUT=""; E_RC=0
  E_OUT="$(check_surface_scan "$to")" || E_RC=$?' '  E_OUT="weird_answer"; E_RC=0')"
# ⛔ THE REF MUST CARRY A COVER (agent-infra#3419). With the bare `delta:$DG_A1..$DG_HEAD`, the
#    merge-only-needs-cover arm refuses a mutant that skips clause (E) too — both rc 3 — so
#    emptying the `*)` body left this cell GREEN and the polarity arm was pinned by nothing.
#    With a cover, clause (E) is the ONLY arm between this mutant and a `clean`, so the cell
#    reds exactly when the polarity regresses. Attribution is pinned by the two assertions
#    below: the shipped recorder ACCEPTS the same vector, and the mutant's stderr is clause
#    (E)'s unreadable-answer refusal (site: scripts/record-review.sh, the `*)` arm's message).
mut_check "M11 clause (E) refuses an UNNAMED check status" 425153 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42515301" refused STUB_EVIDENCE_AT="2025-06-05T00:00:00Z"
rm -f "$(Q2 425153)"
run_record_delta 425153 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42515301" \
    STUB_EVIDENCE_AT="2025-06-05T00:00:00Z"
assert_eq "$RECORD_RC" "0" "20g M11 the SHIPPED recorder ACCEPTS the same covered vector (rc 0) — so clause (E) is the only arm that can refuse the mutant"
assert_contains "$(cat "$T/merr" 2>/dev/null || true)" "could not be READ (rc 0, answer 'weird_answer')" \
    "20g M11 the mutant refused AT CLAUSE (E) — the unreadable-answer arm it mutates — and not downstream"

# M12 — THE RANGE CLAIM. Deleting the (10a) arm must mint `clean` from a cover that
#       never says which range it reviewed — the date-only inference the arm replaced.
# ⛔ RE-TARGETED by the fifth cycle: the bare-needle fallback this cell used to prefix is GONE
#     for an authored range (20h25/20h27), so the arm that now refuses an unclaimed range is the
#     required-stated-range arm. The vector is unchanged; only the line that decides it moved.
MUT="$(mk_mutant rangeclaim '    if [ "$_any" -ne 1 ]; then' '    if false; then')"
mut_check "M12 an unclaimed range is refused" 425154 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42515501" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="Reviewed the diff; no issues found."
# M20 — THE REQUIRED STATED RANGE (20h27). Restoring the bare-needle fallback is the shipped
#       pre-fix state for a body that names ONLY the head: `_any` stays 0, the requirement is
#       bypassed, and because the body names no OTHER commit the token rule has nothing to catch
#       — so the body is accepted. (The en-dash vector 20h25 is NOT usable here any more: the
#       token rule refuses it independently, which would make this cell vacuous — M21 covers the
#       token rule, and M14b/M19b record that the older arms are now defence in depth.)
MUT="$(mk_mutant nodigits '    if [ "$_any" -ne 1 ]; then' '    if false; then')"
mut_check "M20 the stated range is REQUIRED, no alphabet-dependent fallback" 425198 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42519901" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="Reviewed ${DG_HEAD}; no issues found."
# M21 — THE TOKEN RULE (20h30). The structural half of the sixth cycle's fix: with the whole
#       claim scanned for resolvable commits and the narrowing one caught by MEANING, disabling
#       the population re-opens exactly the decoy bypass — the parsed range passes, the narrowed
#       sentence beside it is never examined, and the record is minted over the wider range.
# ⛔ TWO ANCHORS, NOT ONE: the scan line and the rc check that now guards it. Replacing only the
#       scan leaves `_tok_rc` 0 and the mutant would still refuse on the token rule's real answer —
#       the mutation has to restore the pre-fix "empty means nothing to check" shape.
MUT="$(mk_mutant novalley '    _toks="$(printf '\''%s\n'\'' "$_claim" | command grep -oE '\''[0-9a-fA-F]{7,40}'\'' | command tr '\''A-F'\'' '\''a-f'\'' | command sort -u)" || _tok_rc=$?' '    _toks=""; _tok_rc=0')"
mut_check "M21 every resolvable commit in the claim is checked" 425204 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520501" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
Reviewed only ${DG_A1}–${DG_HEAD}; no issues found."
# M22 — THE TIP-RELATIVE ARM (20h33). Disabling it re-accepts `HEAD~1..HEAD` beside the decoy,
#       which is the one narrowing notation the meaning rule cannot reach (no hex token).
# ⛔ THE ANCHOR INCLUDES THE PATTERN LINE, NOT JUST THE `case` — the merge-only arm's
# `case "$_claim" in` is the SAME SUBSTRING one indent deeper, so an anchor of `case "$_claim" in`
# with four leading spaces matched inside the merge-only line and mutated the WRONG ARM; the cell
# then reported "mutant still refused" and the tip-relative arm was left UNMEASURED for a cycle.
# A mutation anchor must be ≥ the whole statement it means to break, not a suffix of another one.
MUT="$(mk_mutant relativehead '    case "$_claim" in
      *HEAD~*|*HEAD^*' '    case "" in
      *HEAD~*|*HEAD^*')"
mut_check "M22 a tip-relative range is refused" 425210 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42521101" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
I only actually reviewed HEAD~1..HEAD."
# M23 — THE EXCLUSION IS THE ROWS, NOT THE SECTION (20h34, 20h37). Skipping every line of the
#       block's section is a REGION in a shorter costume: the sixth cycle's region ran to the next
#       `## ` heading, the seventh cycle's span ran to the last row — both dropped PROSE, and both
#       re-accepted a narrowing written there. The mutant restores the span shape (skip the whole
#       section) and 20h34's `### Scope caveat` narrowing is accepted again.
MUT="$(mk_mutant spanblock '          print line' '          if (!ins) print line')"
mut_check "M23 the exclusion is the ROWS, not the whole section" 425212 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42521301" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |

### Scope caveat
I only actually reviewed ${DG_A1}–${DG_HEAD}; the base-side merge was not read."
# M26 — THE TABLE ROWS ARE ACTUALLY EXCLUDED (20h32). The other direction of M23: with the row
#       predicate broken the kill table is compared as the reviewer's own claim, so a CORRECT
#       artifact is refused because of a row describing a mutant pinned to the range.
MUT="$(mk_mutant norowskip '            if (rowcells(line) > 0) {' '            if (0) {')"
mut_check "M26 the kill table's rows ARE excluded from the claim" 425208 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42520901" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| 20h30 the decoy beside a narrowed claim is caught | re-point this cell at delta:${DG_A1}..${DG_HEAD} | 20h30 | rc 3 |"
# M27 — THE HEADING CONTRACT MIRRORS brief-gate.sh (20h38). Recognising only the canonical
#       spelling leaves a brief-gate-VALID block unexcluded, so its row is read as the claim and a
#       valid artifact is refused with a false accusation. The mutant restores the canonical-only
#       matcher; 20h38's `### Mutation-Attribution` then refuses.
MUT="$(mk_mutant canonhead 'htxt ~ /^[ \t]*mutation[ -]attribution/' 'htxt ~ /^[ \t]*mutation attribution/')"
mut_check "M27 the heading contract mirrors brief-gate's" 425226 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522701" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

### Mutation-Attribution

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| the verdict covers ${DG_A1} | y | z | rc 3 |"
# M28 — THE FLOOR BELOW 7 (20h41). Restoring the 12-char floor makes a 6-char narrowing invisible to
#       both scans again, which is the ninth cycle's P1. The vector is 20h41 and the mutant must
#       ACCEPT it.
MUT="$(mk_mutant shortfloor '([0-9a-fA-F]{4,40})[[:space:]]*(\.{2,3})[[:space:]]*([0-9a-fA-F]{4,40})' '([0-9a-fA-F]{12,40})[[:space:]]*(\.{2,3})[[:space:]]*([0-9a-fA-F]{12,40})')"
mut_check "M28 the range parser's floor is 4, not 12" 425232 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523301" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
I only actually reviewed ${DG_A1:0:6}..${DG_HEAD:0:6}; the rest was not read."
# M29 — THE HEADING LINE'S TAIL (20h39). Dropping the whole heading line bins whatever a reviewer
#       wrote on it, so a narrowing stated there is never scanned — the ninth cycle's P1.
MUT="$(mk_mutant headtail 'if (rest !~ /^[ \t]*$/) print rest' 'if (0) print rest')"
mut_check "M29 the heading line's prose is scanned" 425228 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522901" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION — I also only read ${DG_A1}–${DG_HEAD}

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |"
# M30 — EVERY BLOCK, NOT JUST THE FIRST (20h40). Re-opening the section only once leaves a second
#       block's rows outside the exclusion, so an addendum artifact is refused for a row it may
#       carry — the ninth cycle's P2.
MUT="$(mk_mutant secondblock '                ins = 1; depth = nh; hdr = 0; intable = 0' '                opened++; if (opened > 1) { ins = 0 } else { ins = 1; depth = nh; hdr = 0; intable = 0 }')"
mut_check "M30 every MUTATION-ATTRIBUTION block is excluded" 425230 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523101" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| one | y | z | rc 3 |

## MUTATION ATTRIBUTION (addendum, same verdict)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| two | the row that reddens delta:${DG_A1}..${DG_HEAD} | two | rc 3 |"
# M31 — THE TABLE ENDS (20h42). Never resetting `intable` restores the ninth cycle's unbounded row
#       exclusion: every row to EOF is dropped, so a narrowing in a row AFTER the block is invisible.
MUT="$(mk_mutant openended '              intable = 0        # a blank line or prose ENDS the table (and never re-opens it)' '              intable = intable')"
mut_check "M31 the block's table ENDS at a blank or prose line" 425236 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523701" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | y | z | rc 3 |

| what I actually reviewed | ${DG_A1} | not the rest | rc 3 |"
# M32 — THE ROW RECOGNITION (20h43). Requiring the pipe to be the FIRST non-blank character is the
#       tenth cycle's false block: a valid GFM table without outer pipes, or a bulleted row, is read
#       as the reviewer's claim.
MUT="$(mk_mutant outerpipe 'if (l2 !~ /\|/) return 0' 'if (l2 !~ /^[ \t>]*\|/) return 0')"
mut_check "M32 a table without OUTER pipes is still a row" 425238 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42523901" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

assertion | mutant (reverts the fix) | reddened row | observed
---|---|---|---
x | sed s/rc=80/rc=0/ | A (i) | rc=0
- the guard added at ${DG_A1} | revert it | B (ii) | row red"
# M33 — THE PROSE SKIP DOES NOT SATISFY THE REQUIREMENT (20h44). Putting `_any=1` back before the
#       4-6-char skip restores the eleventh cycle's P1: both refusals cancel, and a body that stated
#       no range records rc 0 with a `delta_range` inferred from dates. The mutant must ACCEPT.
MUT="$(mk_mutant prosenotrange '      if [ -z "$_sfs" ] && [ "${#_sf}" -lt 7 ]; then
        continue
      fi
      _any=1' '      _any=1
      if [ -z "$_sfs" ] && [ "${#_sf}" -lt 7 ]; then
        continue
      fi')"
mut_check "M33 a PROSE-skipped token is not a stated range" 425240 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42524101" accepted STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="The literals 0xdead..0xbeef and f00d..babe are unrelated to this change.
No issues found; the port handling is correct."
# M24 — THE UNRELATED-LINEAGE BOUND (20h36). Dropping the "is it LATER than A" test makes every
#       resolvable token that is not reviewed history a contradiction, which is the seventh
#       cycle's false block: an artifact quoting a commit on an UNRELATED lineage is refused for
#       a commit that cannot narrow A..B at all. The vector is 20h36 and the mutant must REFUSE.
MUT="$(mk_mutant unrelbound '      delta_git "$root" merge-base --is-ancestor "$from" "$_tsha" 2>/dev/null || _r=$?
      [ "$_r" -eq 0 ] || continue' '      :')"
mut_check "M24 only a commit LATER than A can narrow the range" 425220 "$DG_HEAD" "delta:$DG_BASE..$DG_HEAD+comment:42522101" refused STUB_EVIDENCE_AT="2026-02-01T00:00:00Z" STUB_EVIDENCE_BODY="reviewed delta:${DG_BASE}..${DG_HEAD}; no issues found.
For context, the other PR's head was ${DG_UNREL} and it is unrelated to this range."
# M25 — THE MERGE-ONLY CLAIM FORM (20h35). Reading the RAW body in the merge-only arm re-accepts
#       a cover whose only mention of A is a kill-table row — a table is not a claim, and that arm
#       exists to require the VERDICT at A.
MUT="$(mk_mutant rawbody '      case "$_claim" in' '      case "$EVIDENCE_BODY" in')"
mut_check "M25 the merge-only arm reads the CLAIM, not the raw body" 425216 "$DG_HEAD" "delta:$DG_A1..$DG_HEAD+comment:42521701" accepted STUB_EVIDENCE_AT="2025-06-05T00:00:00Z" STUB_EVIDENCE_BODY="No issues found.

## MUTATION ATTRIBUTION (agent-infra#3442)

| assertion | mutant (reverts the fix) | reddened row | observed |
|---|---|---|---|
| x | the row that reddens delta:${DG_A1}..${DG_HEAD} | z | rc 3 |"
# M34 — THE DELTA PATH'S REPLACE PIN (20i1). `delta_git`'s export is a SEPARATE site from the
#       carry walk's `local -x` export that `tests/record-review/run.sh` (12)/(13) mutate, so
#       until this cell NOTHING pinned it: the line could be deleted and every delta vector stayed
#       green. With `GIT_NO_REPLACE_OBJECTS` dropped, the planted replacement is read, the
#       hand-edited merge compares EQUAL to the automatic one, the range classifies merge-only,
#       and the vector the shipped recorder REFUSES (20i1) is ACCEPTED.
git replace "$DG_HI_H" "$DG_HI_FAKE" >/dev/null 2>&1 || true
MUT="$(mk_mutant nodelreplace '  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null command git -C "$root" "$@"' '  GIT_GRAFT_FILE=/dev/null command git -C "$root" "$@"')"
mut_check "M34 the delta path's REPLACE pin" 425150 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H+comment:42515001" accepted STUB_BASE_SHA="$DG_HI_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
git replace -d "$DG_HI_H" >/dev/null 2>&1
# M35 — THE DELTA PATH'S GRAFTS-FILE PIN, measured by ATTRIBUTION because BOTH scripts refuse.
#       Dropping only `GIT_GRAFT_FILE` leaves the graft readable: the merge stops being a merge,
#       the commit becomes ordinary AUTHORED content, and the refusal moves from the evil-merge
#       sentence to the authored COUNT form (20i2). That move IS the proof the export is
#       load-bearing; `mut_check … refused` could not see it.
printf '%s %s\n' "$DG_HI_H" "$DG_HI_L" > "$DG/.git/info/grafts"
MM=$((MM+1))
MUT="$(mk_mutant nograftfile '  GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null command git -C "$root" "$@"' '  GIT_NO_REPLACE_OBJECTS=1 command git -C "$root" "$@"')"
if [ -s "${MUT:-}" ]; then
    rm -f "$(Q2 425150)"
    mut_run "$MUT" 425152 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H" STUB_BASE_SHA="$DG_HI_B"
    if [ "$RECORD_RC" != "0" ] && command grep -q "contains authored content" "$T/merr" 2>/dev/null; then
        MM_OK=$((MM_OK+1)); ok "20g M35 the delta path's GRAFTS-FILE pin: with only the replace export the graft is READ, the refusal becomes the authored COUNT form, so GIT_GRAFT_FILE IS load-bearing and is covered here"
    else
        bad "20g M35 the grafts-file pin is vacuously green — the mutant's refusal is not the graft-honouring classification (rc=$RECORD_RC)"
    fi
else
    bad "20g M35 the mutant could not be built (mutation anchor missing from the recorder) — this vector was NOT measured"
fi
rm -f "$DG/.git/info/grafts"
# M21b — THE rc CHECK, WHICH M21 DOES NOT MEASURE (cycle-2 review). M21 replaces the SCAN LINE, so
#        it proves the scan exists, not that a FAILED scan is refused: delete only the rc check and
#        every vector plus M21 stays green while "no tokens" and "the scan did not run" collapse
#        back into one value. The sort shim is what makes a pipeline member fail for real.
printf '#!/bin/sh\nif [ "$1" = "-u" ]; then exit 2; fi\nexec /usr/bin/sort "$@"\n' > "$T/bin/sort"; chmod +x "$T/bin/sort"
MUT="$(mk_mutant norgcheck '    if [ "$_tok_rc" -gt 1 ]; then' '    if false; then')"
mut_check "M21b the rc check on the token scan" 425155 "$DG_HI_H" "delta:$DG_HI_L..$DG_HI_H+comment:42515501" accepted STUB_BASE_SHA="$DG_HI_B" STUB_EVIDENCE_AT="2026-01-01T00:00:00Z"
rm -f "$T/bin/sort"
# M36 — THE MERGE-DRIVER REFUSAL (20i3). Deleting it re-accepts a checkout whose oracle is steered
#       by a driver the lane owns, which is the false PASS the arm exists to stop.
printf 'u.txt merge=union\n' > "$DG/.gitattributes"
MUT="$(mk_mutant noambientattr '    if [ -n "$_wt_amb" ]; then' '    if false; then')"
mut_check "M36 the AMBIENT-ATTRIBUTES refusal" 425156 "$DG_UN_H" "delta:$DG_UN_L..$DG_UN_H+comment:42515601" accepted STUB_BASE_SHA="$DG_UN_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
rm -f "$DG/.gitattributes"
# M37 — THE CONFIG-DRIVER REFUSAL. ⛔ NO AMBIENT ATTRIBUTE IN THIS CELL'S FIXTURE, deliberately: with
#       one present the mutant would still refuse on the attribute arm and the cell would be vacuous.
#       Config alone is the over-block this arm accepts (a driver key that no attribute uses), and the
#       cell measures that it is load-bearing.
git config merge.hidrv.driver true || true
MUT="$(mk_mutant nodriver '    if [ -n "$_drivers" ] || [ -n "$_attr_amb" ]; then' '    if [ -n "$_attr_amb" ]; then')"
mut_check "M37 the CONFIG merge-driver refusal" 425159 "$DG_UN_H" "delta:$DG_UN_L..$DG_UN_H+comment:42515901" accepted STUB_BASE_SHA="$DG_UN_B" STUB_EVIDENCE_AT="2026-01-01T00:00:00Z"
git config --unset merge.hidrv.driver 2>/dev/null || true
# M38 — THE ORACLE NEUTRALISATION (20i6). With the box-global attributes file in place, dropping the
#       neutralised read lets the MACHINE's `merge=union` decide the answer: the hand resolution
#       compares equal, the range becomes merge-only, and the cover naming A is enough.
#
# ⛔ `XDG_CONFIG_HOME=` IS PART OF THIS CELL'S PREMISE, NOT TIDINESS (measured on a runner, #3712).
#       git resolves the DEFAULT user-level attributes file as `$XDG_CONFIG_HOME/git/attributes`
#       when that variable holds a NON-EMPTY value, and falls back to `$HOME/.config/git/attributes`
#       when it is unset OR EMPTY — which is why the pin is `XDG_CONFIG_HOME=` (empty) and NOT
#       `env -u XDG_CONFIG_HOME`. With an inherited NON-EMPTY value the fixture below is written
#       somewhere git never reads, the mutant's raw `merge-tree` CONFLICTS again, and the cell
#       refuses at 3 for a reason that has nothing to do with the guard it mutates: VACUOUS,
#       reported against itself. The 20i6 control above pins the same variable for exactly this
#       reason; this cell must too. GitHub runners export
#       `XDG_CONFIG_HOME=/home/runner/.config` (see
#       `scripts/orchestrator-harness/worker-terminal.test.sh:36`), so an unpinned mutant is green
#       on a dev box and red on CI — measured on THIS branch's pre-#3755 base: `PASS=1453 FAIL=2`,
#       with `20g M38` and the `MUTATION-MATRIX` rollup the two red rows, total unchanged at 1455.
#       ⛔ THAT MEASUREMENT NO LONGER RE-DERIVES ON THE MERGED TREE, so do not quote it as current:
#       `origin/main` pins the variable SUITE-WIDE (`export XDG_CONFIG_HOME="$F_HOME/.config"`,
#       #3755), so after the merge this cell stays green even with this per-vector pin removed. The
#       pin is kept as belt-and-braces — it makes the cell independent of that suite-level line —
#       not as the thing carrying the fix.
mkdir -p "$F_HOME/.config/git"
printf 'u.txt merge=union\n' > "$F_HOME/.config/git/attributes"
MUT="$(mk_mutant nonneutral '    want="$(delta_git_neutral "$root" merge-tree --write-tree "$p1" "$p2" 2>/dev/null)"' '    want="$(delta_git "$root" merge-tree --write-tree "$p1" "$p2" 2>/dev/null)"')"
mut_check "M38 the neutralised oracle" 425160 "$DG_UN_H" "delta:$DG_UN_L..$DG_UN_H+comment:42516001" accepted XDG_CONFIG_HOME= STUB_BASE_SHA="$DG_UN_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
rm -f "$F_HOME/.config/git/attributes"
# M39 — THE ATTRIBUTES-DRIFT ARM (20i7). Dropping it re-accepts a TRACKED `.gitattributes` whose
#       worktree copy steers the oracle — the P0 the previous commit introduced by removing `-m`.
git checkout -q attr_lane >/dev/null 2>&1 || true
printf 'w.txt merge=union\n' > "$DG/.gitattributes"
MUT="$(mk_mutant nodrift '    _adrift="$(delta_git "$root" diff --name-only "$m" -- '\''*.gitattributes'\'' '\''.gitattributes'\'' 2>/dev/null)"' '    _adrift=""')"
mut_check "M39 the attributes-drift arm" 425161 "$DG_AT_H" "delta:$DG_AT_L..$DG_AT_H+comment:42516101" accepted STUB_BASE_SHA="$DG_AT_B" STUB_EVIDENCE_AT="2025-08-15T00:00:00Z"
git checkout -- .gitattributes 2>/dev/null || true
# M8 (the tier arm) is RETIRED WITH ITS ARM: the unsigned local-record premise was a
# forgery vector (review minted a signed `clean` from one `printf`), so there is no
# tier left to launder into `clean`. 20h6 keeps its refusal, now reached through the
# mandatory-cover arm.
echo "   MUTATION-MATRIX($MM_OK/$MM)"
set -e
if [ "$MM" -eq "$MM_OK" ]; then ok "20g MUTATION-MATRIX($MM_OK/$MM) every dispatched cell behaved as its vector predicted — the guard-load-bearing cells AND M1b, which deliberately measures the OPPOSITE (that the A==B arm is REDUNDANT because the empty-diff arm already refuses it); the other delta arms are pinned by refusal vectors only, not by a mutant"; else bad "20g MUTATION-MATRIX($MM_OK/$MM) — a guard is vacuous"; fi

cd "$ORIG_PWD" 2>/dev/null || cd "$T" || true
echo ""
echo "  PASS=$PASS FAIL=$FAIL"
SUMMARY_PRINTED=1   # the sentinel: only from here may the EXIT trap pass an exit status through
[ "$FAIL" -eq 0 ] || { echo "  ❌ FAILURES — fix and re-run"; exit 1; }
echo "  ✅ all checks passed"
exit 0
