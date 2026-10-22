#!/usr/bin/env bash
# tests/review-pr/run.sh — scripts/review-pr.sh, the review seam a lander runs.
#
# THE WALL THIS SUITE GUARDS. `pipeline-compliance` check (c) accepts one artifact:
# a record-review.sh marker bound to the PR's CURRENT head. A `clean` record
# requires `--evidence <artifact>` (tortoise#7391), so the artifact must be a real,
# posted review comment. Until this seam existed, obtaining it was a HAND
# COMPOSITION — spawn a prompt, post what it said, decide whether it was clean —
# and thirteen finished PRs could not land on that gap.
#
# WHAT IS DRIVEN HERE, AND HOW. The script is run for real (no function extraction,
# no grep of its text for intent) against three fakes: `gh` (on PATH), `pi` (via
# REVIEW_PR_PI) and the recorder (via REVIEW_PR_RECORD_SH). Every assertion is about
# an OBSERVABLE: the recorder's argv, the record file, the posted comment body, the
# reviewer's prompt, the exit code, and whether the reviewer was paid for at all.
#
#   §A a CLEAN verdict          => record written, bound to the reviewed head
#   §B a verdict WITH findings  => NO record, non-zero exit, findings printed
#   §C an unresolvable repo     => loud refusal, no reviewer spawned, NO record
#   §D no auth                  => refusal, no reviewer, NO record
#   §E `pi` unavailable         => refusal, NO comment (nothing to record either)
#   §F reviewer with no verdict => failure (not "issues"), NO comment, NO record
#   §G head moved mid-review    => refusal, NO record against the new head
#   §H already recorded at head => refusal to re-record an unchanged head
#   §L a CLEAN verdict contradicted by its own [P1] line => refused, no record
#   §I an ambient GH_REPO       => cannot choose the repo; the url does
#   §J never edits a PR body    => source-level, non-comment lines
#   §L a CLEAN verdict contradicted by its own blocking finding => refused, no record
#   §M rc=0 without the PR-BODY marker (the artifact check (c) reads) => exit 9
#   §N an UNSIGNED marker => exit 9, the missing signing key named
#   §O a spawn-point load refusal (rc=76) => exit 75, nothing consumed
#   §P an oversized diff stays out of the single-argv prompt, with a fetch instruction
#   §Q a blocking finding in LIST/TABLE markup still contradicts CLEAN (§L is one form)
#   §R an earlier unsigned marker does not shadow the signed one
#   §S the reviewer printed CLEAN but EXITED non-zero => no verdict, no record
#   §T a warning on a SUCCESSFUL gh read is ignored, not a parse error (the #2284 class)
#   §U the reviewer CHILD runs with GH_REPO pinned to the resolved repo
#   §V `ISSUES 0` is clean; `ISSUES n>0` is NEVER converted, even when every line parses P3
#   §W the no-URL comment fallback must match the body just posted, or refuse
#   §K MUTATION: the clean-only guard removed => §B's scenario RECORDS, i.e. the
#      guard is what makes §B pass (a suite that only proves the happy path would
#      let a fail-open land green — the #2148/#1741 lesson).
#
# Assertion-count PIN at the tail: a whole section was once deleted elsewhere and
# the suite still said ALL PASSED; the pin is a tripwire for section loss, not a
# proof of coverage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$ROOT/scripts/review-pr.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '   ✅ %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '   ❌ %s\n' "$*"; }
ck()   { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }

[ -f "$SRC" ] || { echo "❌ no review-pr.sh at $SRC"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/review-pr-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export TMP
mkdir -p "$TMP/bin" "$TMP/home/.pi/agent/reviews"

REPO_FIXTURE="daniel-ospina/agent-infra"
HEAD_FIXTURE="da91f8edbd58736f4db4c0414baaecb0954d067f"
HEAD2_FIXTURE="1111111111111111111111111111111111111111"
# ⛔ EVERY fixture the FAKES read must be EXPORTED: they are separate processes, so a
# shell variable set in this test is invisible to them — measured: without these the
# fake `gh` answered with an empty url, every scenario refused with rc=3, and the
# suite read as "the script is broken" instead of "the fixture never reached it".
export REPO_FIXTURE HEAD_FIXTURE HEAD2_FIXTURE
export FIXTURE_URL FIXTURE_REPO FIXTURE_TITLE FIXTURE_STATE FIXTURE_BASE FIXTURE_BODY \
       FIXTURE_DIFF FIXTURE_DIFF_BYTES FIXTURE_ISSUE_URL FIXTURE_ISSUE_BODY FIXTURE_CID FIXTURE_AUTH_RC \
       FIXTURE_AUTH_MSG FIXTURE_PI_RC FIXTURE_MOVE_HEAD_TO FIXTURE_RECORD_RC \
       FIXTURE_MARKER_MISSING FIXTURE_NO_KEY FIXTURE_GH_WARNING FIXTURE_NO_URL FIXTURE_FOREIGN_BODY FIXTURE_API_ROW FIXTURE_DIFF_MULTIBYTE
FINDINGS_FIXTURE='[P1] scripts/x.sh:42 — the guard returns 0 on a failed read — a red gate reports green
[P2] tests/y.sh:7 — the fixture would pass on the pre-fix code — vacuous'

# ── the fake gh: every read the script makes, and a record of HOW it was called ─
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Records the WHOLE argv and whether GH_REPO leaked into the environment, then
# answers the reads review-pr.sh makes. Fixtures come in through FIXTURE_*.
printf 'GHREPO=%s ARGV=%s\n' "${GH_REPO:-<unset>}" "$*" >> "$TMP/gh-calls.log"
# A WARNING ON A SUCCESSFUL READ (§T): gh does this (deprecation notices, API warnings) and
# the seam must not turn it into a parse error — the #2284 class, in the seam itself.
[ -n "${FIXTURE_GH_WARNING:-}" ] && printf '%s\n' "$FIXTURE_GH_WARNING" >&2
cmd="${1:-}"; shift || true
case "$cmd" in
  auth) printf '%s\n' "${FIXTURE_AUTH_MSG:-Logged in to github.com}"; exit "${FIXTURE_AUTH_RC:-0}" ;;
  api)
    if [ -n "${FIXTURE_API_ROW:-}" ]; then printf '%s\n' "$FIXTURE_API_ROW"; exit 0; fi
    if [ -f "$TMP/comment.md" ]; then
      b="$(base64 < "$TMP/comment.md" | tr -d '\n')"
      [ "${FIXTURE_FOREIGN_BODY:-0}" = "1" ] && b="$(printf 'someone else wrote this' | base64)"
      printf '%s\t%s\n' "${FIXTURE_CID:-9001}" "$b"; exit 0
    fi
    exit 1 ;;
  issue) printf '## 1876 the linked issue\n%s\n' "${FIXTURE_ISSUE_BODY:-fixture issue body}"; exit 0 ;;
  pr)
    sub="${1:-}"; shift || true
    prnum="${1:-}"; shift || true
    json=""; body_file=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) json="${2:-}"; shift 2 ;;
        --body-file) body_file="${2:-}"; shift 2 ;;
        --jq) shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    case "$sub" in
      view)
        case "$json" in
          "url,headRefOid,title,state,baseRefName")
            printf '%s\t%s\t%s\t%s\t%s\n' "${FIXTURE_URL:-}" "$(cat "$TMP/head")" \
              "${FIXTURE_TITLE:-fixture title}" "${FIXTURE_STATE:-OPEN}" "${FIXTURE_BASE:-main}" ;;
          body) cat "$TMP/body.md" 2>/dev/null || printf '%s\n' "${FIXTURE_BODY:-fixture body}" ;;
          closingIssuesReferences) [ -n "${FIXTURE_ISSUE_URL:-}" ] && printf '%s\n' "$FIXTURE_ISSUE_URL"; ;;
          headRefOid) cat "$TMP/head" ;;
          *) echo "fake-gh: unhandled pr view --json $json" >&2; exit 1 ;;
        esac ;;
      diff)
        # A huge diff is GENERATED here, never carried through the environment: a
        # 200 KB exported variable is itself past the single-string exec limit on this
        # box, which would test the harness instead of the seam (§P).
        if [ -n "${FIXTURE_DIFF_BYTES:-}" ]; then
          printf 'diff --git a/big b/big\n'
          if [ "${FIXTURE_DIFF_MULTIBYTE:-0}" = "1" ]; then
            awk -v n="$FIXTURE_DIFF_BYTES" 'BEGIN { for (i = 0; i < n; i++) printf "\342\206\222" }'
          else
            head -c "$FIXTURE_DIFF_BYTES" /dev/zero | tr '\0' 'x'
          fi
          printf '\n'
        else
          printf '%s\n' "${FIXTURE_DIFF:-diff --git a/x b/x}"
        fi ;;
      comment)
        # Each posted comment is kept UNDER ITS OWN NAME (the seam posts a notes comment
        # before the verdict comment), and the last one is also $TMP/comment.md.
        n=$(( $(cat "$TMP/comment-n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/comment-n"
        cp "$body_file" "$TMP/comment-$n.md" 2>/dev/null
        cp "$body_file" "$TMP/comment.md" 2>/dev/null
        [ "${FIXTURE_NO_URL:-0}" = "1" ] && exit 0
        printf 'https://github.com/%s/pull/%s#issuecomment-%s\n' \
          "${FIXTURE_REPO:-$REPO_FIXTURE}" "$prnum" "${FIXTURE_CID:-9001}" ;;
      *) echo "fake-gh: unhandled pr sub '$sub'" >&2; exit 1 ;;
    esac ;;
  *) echo "fake-gh: unhandled cmd '$cmd'" >&2; exit 1 ;;
esac
EOF

# ── the fake reviewer: a `pi -p` stand-in that reports what it was handed ─────
cat > "$TMP/bin/fake-pi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TMP/pi-argv.txt"
# The prompt is the LAST argument (pi -p <flags> "<prompt>").
for a in "$@"; do prompt="$a"; done
printf '%s' "$prompt" > "$TMP/pi-prompt.txt"
printf 'ran\n' >> "$TMP/pi-runs.txt"
printf 'GHREPO=%s\n' "${GH_REPO:-<unset>}" >> "$TMP/pi-env.txt"
# A head move DURING the review (the caller must refuse to record it).
[ -n "${FIXTURE_MOVE_HEAD_TO:-}" ] && printf '%s\n' "$FIXTURE_MOVE_HEAD_TO" > "$TMP/head"
cat "$TMP/reviewer-out" 2>/dev/null
exit "${FIXTURE_PI_RC:-0}"
EOF

# ── the fake recorder: proves WHAT review-pr.sh asked record-review.sh to bind ─
cat > "$TMP/bin/fake-record" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMP/record-argv.txt"
pr="$1"; sha="$2"; verdict="$3"; repo="$4"; shift 4 || true
ev=""
while [ "$#" -gt 0 ]; do case "$1" in --evidence) ev="${2:-}"; shift 2 ;; *) shift ;; esac; done
owner="${repo%%/*}"; name="${repo##*/}"
mkdir -p "$HOME/.pi/agent/reviews"
printf '{"pr":%s,"head_sha":"%s","mint":"fresh","evidence":"%s","verdict":"%s","repo":"%s","reviewed_at":"2026-10-21T00:00:00Z"}\n' \
  "$pr" "$sha" "$ev" "$verdict" "$repo" > "$HOME/.pi/agent/reviews/${owner}-${name}-${pr}.json"
# The recorder's OTHER artifact: the marker it appends to the PR body (signed, unless
# the key is missing). check (c) reads THIS, not the JSON — so the fake must produce it
# for the seam's post-record verification to be exercised at all.
if [ "${FIXTURE_MARKER_MISSING:-0}" = "1" ]; then exit "${FIXTURE_RECORD_RC:-0}"; fi
if [ "${FIXTURE_NO_KEY:-0}" = "1" ]; then
  printf '\nreview recorded: reviews/%s.json verdict=%s @ %s (%s)\n' "$pr" "$verdict" "$sha" "$repo" >> "$TMP/body.md"
else
  printf '\nreview recorded: reviews/%s.json verdict=%s @ %s (%s) sig=%064d\n' "$pr" "$verdict" "$sha" "$repo" 0 >> "$TMP/body.md"
fi
exit "${FIXTURE_RECORD_RC:-0}"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/fake-pi" "$TMP/bin/fake-record"
export PATH="$TMP/bin:$PATH"

# reset <scenario> — one clean slate per scenario (fakes share $TMP, so state must go).
reset() {
  rm -f "$TMP/gh-calls.log" "$TMP/pi-argv.txt" "$TMP/pi-prompt.txt" "$TMP/pi-runs.txt" \
        "$TMP/record-argv.txt" "$TMP/comment.md" "$TMP/comment-n" "$TMP"/comment-[0-9]*.md "$TMP/reviewer-out" "$TMP/rc" "$TMP/pi-env.txt"
  rm -rf "$TMP/home/.pi/agent/reviews"; mkdir -p "$TMP/home/.pi/agent/reviews"
  printf '%s\n' "$HEAD_FIXTURE" > "$TMP/head"
  printf '%s\n' "This PR fixes the thing. Closes #1876." > "$TMP/body.md"
  FIXTURE_MARKER_MISSING=0; FIXTURE_NO_KEY=0; FIXTURE_DIFF_BYTES=""; FIXTURE_GH_WARNING=""
  FIXTURE_NO_URL=0; FIXTURE_FOREIGN_BODY=0; FIXTURE_API_ROW=""; FIXTURE_DIFF_MULTIBYTE=0
  mkdir -p "$TMP/tmp"
  FIXTURE_URL="https://github.com/$REPO_FIXTURE/pull/2284"
  FIXTURE_REPO="$REPO_FIXTURE"; FIXTURE_TITLE="a fixture PR"; FIXTURE_STATE="OPEN"; FIXTURE_BASE="main"
  FIXTURE_BODY="This PR fixes the thing. Closes #1876."
  FIXTURE_DIFF="diff --git a/scripts/x.sh b/scripts/x.sh
+the change under review"
  FIXTURE_ISSUE_URL="https://github.com/$REPO_FIXTURE/issues/1876"
  FIXTURE_ISSUE_BODY="the linked issue body"
  FIXTURE_CID="9001"; FIXTURE_AUTH_RC=0; FIXTURE_PI_RC=0
  FIXTURE_MOVE_HEAD_TO=""; FIXTURE_RECORD_RC=0
  unset GH_REPO
}

# run <script> [args...] — drives the REAL script under the fakes.
run() {
  local script="$1"; shift
  HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" \
    bash "$script" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt"
  echo $? > "$TMP/rc"
}
rc_of() { cat "$TMP/rc"; }
out_has() { case "$(cat "$TMP/out.txt")" in *"$1"*) return 0;; *) return 1;; esac; }
err_has() { case "$(cat "$TMP/err.txt")" in *"$1"*) return 0;; *) return 1;; esac; }
no_record() { [ ! -f "$TMP/record-argv.txt" ]; }
no_comment() { [ ! -f "$TMP/comment.md" ]; }
no_reviewer() { [ ! -f "$TMP/pi-runs.txt" ]; }

echo "=== review-pr.sh — the review seam ==="

# ── §A a CLEAN verdict records, bound to the reviewed head ───────────────────
echo; echo "§A clean verdict => record bound to the head"
reset; printf '[P3] scripts/x.sh:9 — a non-blocking style nit (does not block)\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "exit 0 on a CLEAN verdict (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "record-review.sh WAS called"
want="$REPO_FIXTURE"; [ "$(cat "$TMP/record-argv.txt" 2>/dev/null | head -1)" = \
  "2284 $HEAD_FIXTURE clean $want --evidence comment:9001" ]
ck $? "…with <PR> <reviewed-head> clean <repo-from-url> --evidence comment:<id> (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
rec="$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json"
grep -q "\"head_sha\":\"$HEAD_FIXTURE\"" "$rec" 2>/dev/null
ck $? "…and the record file is bound to the head that was REVIEWED"
grep -q '"verdict":"clean"' "$rec" 2>/dev/null; ck $? "…with verdict=clean"
[ -f "$TMP/comment.md" ]; ck $? "the findings were posted as a PR comment (the --evidence artifact)"
out_has "SIGNED marker bound to this head is present in the PR body"; ck $? "…and success is claimed only after the SIGNED body marker is read back (the artifact check (c) consumes)"
grep -q 'Outcome: clean' "$TMP/comment.md" 2>/dev/null; ck $? "…and the comment states the outcome explicitly (record-review.sh's veto reads it)"
# The P3 note is posted as its OWN comment, and the EVIDENCE body must not quote it:
# record-review.sh's veto greps the evidence body, and its arm-(1) markers are
# unconditional, so reviewer prose there could refuse a genuinely clean verdict.
if grep -lq "a non-blocking style nit" "$TMP"/comment-[0-9]*.md 2>/dev/null; then rc=0; else rc=1; fi
ck $rc "…posting the reviewer's P3 note as a NON-BLOCKING note in its OWN comment (clean = zero P0/P1/P2)"
case "$(cat "$TMP/comment.md")" in *"a non-blocking style nit"*) rc=1;; *) rc=0;; esac
ck $rc "…and keeping the reviewer's prose OUT of the evidence body (the recorder's veto scans it)"
P="$(cat "$TMP/pi-prompt.txt" 2>/dev/null)"
case "$P" in *"the change under review"*) rc=0;; *) rc=1;; esac; ck $rc "the reviewer's prompt carries the DIFF (self-contained, no checkout needed)"
case "$P" in *"This PR fixes the thing"*) rc=0;; *) rc=1;; esac; ck $rc "…and the PR's CLAIMED behaviour"
case "$P" in *"the linked issue body"*) rc=0;; *) rc=1;; esac; ck $rc "…and the linked issue"
case "$P" in *'web_search(model="sonar")'*) rc=0;; *) rc=1;; esac; ck $rc "…and names research rung 2 explicitly (web_search model=\"sonar\")"
case "$(cat "$TMP/pi-argv.txt")" in *"--no-session"*) rc=0;; *) rc=1;; esac; ck $rc "…spawned with --no-session (a genuinely fresh context)"

# ── §B findings => NO record, non-zero, findings printed ─────────────────────
echo; echo "§B verdict with findings => NO record"
reset; printf '%s\nISSUES 2\n' "$FINDINGS_FIXTURE" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" != "0" ]; ck $? "exit NON-ZERO when the reviewer found issues (rc=$(rc_of))"
[ "$(rc_of)" = "7" ]; ck $? "…specifically 7 (issues), not a generic failure"
no_record; ck $? "NO record was written (record-review.sh never called)"
no_record && [ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]; ck $? "…and no record file exists"
out_has "[P1] scripts/x.sh:42"; ck $? "the findings are PRINTED to stdout"
out_has "[P2] tests/y.sh:7 — the fixture would pass"; ck $? "…every one of them"
grep -q 'Outcome: not-clean' "$TMP/comment.md" 2>/dev/null
ck $? "…and the posted comment declares the non-clean outcome (the artifact tells the truth)"

# ── §C an unresolvable repo refuses loudly, before any review is paid for ────
echo; echo "§C unresolvable repo => loud refusal, no reviewer, no record"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
FIXTURE_URL="https://gitlab.example.com/someone/elsewhere/pull/2284"
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "exit 3 (evidence failure) (rc=$(rc_of))"
err_has "will not guess"; ck $? "the refusal names the cause (the url is not github.com/<o>/<r>/pull/<n>)"
err_has "https://gitlab.example.com/someone/elsewhere/pull/2284"; ck $? "…and quotes the unresolvable url it saw"
no_reviewer; ck $? "NO reviewer was spawned (no review paid for)"
no_record; ck $? "NO record was written"
# …and an EMPTY url (a broken read) is refused the same way, never defaulted.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_URL=""
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "an EMPTY url is also refused (exit 3), never defaulted to a repo"
no_record; ck $? "…and writes no record"

# ── §D no auth ───────────────────────────────────────────────────────────────
echo; echo "§D no GitHub auth => refusal"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_AUTH_RC=1; FIXTURE_AUTH_MSG="gh: not logged in"
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "exit 3 with no auth (rc=$(rc_of))"
err_has "no GitHub auth"; ck $? "…naming the cause"
no_reviewer; ck $? "…no reviewer spawned"
no_record; ck $? "…no record written"

# ── §E pi unavailable ───────────────────────────────────────────────────────
echo; echo "§E reviewer binary unavailable => refusal, nothing posted"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$TMP/home" REVIEW_PR_PI="$TMP/bin/does-not-exist" REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" \
  bash "$SRC" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "4" ]; ck $? "exit 4 when the reviewer binary is unavailable (rc=$(rc_of))"
err_has "not executable/on PATH"; ck $? "…naming the cause"
no_comment; ck $? "…nothing posted"
no_record; ck $? "…no record written"

# ── §F the reviewer ran but produced NO verdict ──────────────────────────────
echo; echo "§F no verdict => failure, not 'issues', not a record"
reset; printf 'I looked at the diff and it seems fine to me.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "exit 6 (no verdict), distinct from 7 (issues) (rc=$(rc_of))"
err_has "NO VERDICT"; ck $? "…naming what was missing"
no_comment; ck $? "no comment posted (there is no review to post)"
no_record; ck $? "no record written"
# A crashed reviewer that exits non-zero WITHOUT a verdict is the same failure.
reset; printf '' > "$TMP/reviewer-out"; FIXTURE_PI_RC=1
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a crashed reviewer (rc!=0, empty transcript) is exit 6, never read as a verdict"
no_record; ck $? "…and writes no record"

# ── §G the head moved during the review ─────────────────────────────────────
echo; echo "§G head moved mid-review => refuse, never certify an unreviewed head"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_MOVE_HEAD_TO="$HEAD2_FIXTURE"
run "$SRC" 2284
[ "$(rc_of)" = "8" ]; ck $? "exit 8 when the head moved (rc=$(rc_of))"
err_has "MOVED"; ck $? "…naming the move"
no_record; ck $? "NO record written against the NEW head (that revision was never reviewed)"
no_comment; ck $? "…and NOTHING was posted — a clean artifact created after the move would be ACCEPTED by the recorder against the new head"

# ── §H never re-record an unchanged head ────────────────────────────────────
echo; echo "§H already recorded at this head => refuse to dilute the evidence"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
printf '{"pr":2284,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"%s"}\n' "$HEAD_FIXTURE" "$REPO_FIXTURE" \
  > "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json"
run "$SRC" 2284
[ "$(rc_of)" = "5" ]; ck $? "exit 5 when a clean record already exists at this head (rc=$(rc_of))"
err_has "ALREADY EXISTS"; ck $? "…naming the existing record and why a second one is refused"
no_reviewer; ck $? "no reviewer spawned (no money spent re-proving a recorded head)"
no_record; ck $? "…and the existing record is untouched"

# ── §I an ambient GH_REPO cannot choose the repo ────────────────────────────
echo; echo "§I ambient GH_REPO does not pick the repo — the PR's url does"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
GH_REPO="evil-org/evil-repo" run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "still succeeds (rc=$(rc_of))"
case "$(cat "$TMP/record-argv.txt" 2>/dev/null)" in
  *"clean $REPO_FIXTURE "*) rc=0;; *) rc=1;;
esac; ck $rc "…recording against the url's repo, NOT \$GH_REPO (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
if grep -qv 'GHREPO=<unset>' "$TMP/gh-calls.log" 2>/dev/null; then rc=1; else rc=0; fi
ck $rc "…because every gh lookup ran with GH_REPO UNSET (an inherited global is a repo nobody named, #2235)"
# …and an explicit --repo that CONFLICTS with the url is refused, not obeyed.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284 --repo evil-org/evil-repo
[ "$(rc_of)" = "3" ]; ck $? "--repo conflicting with the PR's url is REFUSED (exit 3)"
err_has "repo conflict"; ck $? "…naming the conflict"
no_record; ck $? "…no record written"

# ── §J never edits a PR body ────────────────────────────────────────────────
echo; echo "§J the tool never edits a PR body (a body edit wipes a recorded marker)"
# Non-comment lines only: the header legitimately DISCUSSES body edits.
CODE="$(grep -v '^[[:space:]]*#' "$SRC" | grep -v '^[[:space:]]*$')"
case "$CODE" in *"gh pr edit"*) rc=1;; *) rc=0;; esac; ck $rc "no 'gh pr edit' in the executable lines"
case "$CODE" in *"-X PATCH"*) rc=1;; *) rc=0;; esac; ck $rc "no '-X PATCH' (the marker-destroying body write) in the executable lines"

# ── §L a CLEAN verdict that contradicts its own blocking finding ─────────────
echo; echo "§L CLEAN that carries a blocking finding => refused (the verdict must agree with its lines)"
reset; printf '[P1] scripts/x.sh:42 — a real blocking bug\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "exit 7 when the verdict says CLEAN but a [P1] line is present (rc=$(rc_of))"
no_comment; ck $? "NO comment posted — the refusal runs BEFORE the artifact exists (a fail-closed check placed after the side effect fails open)"
err_has "self-contradicting"; ck $? "…naming the contradiction"
err_has "[P1] scripts/x.sh:42"; ck $? "…and printing the finding it refused to record over"
no_record; ck $? "NO record written"
no_record && [ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]; ck $? "…and no record file exists"

# ── §M the recorder said rc=0 but the BODY MARKER never landed ───────────────
echo; echo "§M rc=0 without the body marker => exit 9, no false success"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_MARKER_MISSING=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "exit 9 when the record exists but the PR body carries no marker (#1717's fail-open) (rc=$(rc_of))"
err_has "no marker bound to"; ck $? "…naming the artifact check (c) actually reads"
err_has "Re-run the recorder"; ck $? "…and giving the idempotent remedy"

# ── §N an unsigned marker is named, never reported as green ─────────────────
echo; echo "§N unsigned marker => exit 9, the missing key named"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_NO_KEY=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "exit 9 on an UNSIGNED marker (rc=$(rc_of))"
err_has "AI_REVIEW_GATE_KEY"; ck $? "…naming the missing signing key as the cause"

# ── §O the spawn-point load gate is not a reviewer crash ────────────────────
echo; echo "§O spawn-point refusal (rc=76) => exit 75, named as a capacity event"
reset; printf '' > "$TMP/reviewer-out"; FIXTURE_PI_RC=76
run "$SRC" 2284
[ "$(rc_of)" = "75" ]; ck $? "exit 75 (re-dispatch) not 6 (reviewer failure) (rc=$(rc_of))"
err_has "NOT STARTED"; ck $? "…saying the reviewer never started"
err_has "Nothing was consumed"; ck $? "…and that nothing was paid for"
no_comment; ck $? "no comment posted"

# ── §P a prompt too large for one argv drops the diff instead of dying ──────
echo; echo "§P an oversized diff never rides into one argv (truncated, with a fetch instruction)"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "still reviews (rc=$(rc_of)) — a huge diff is not fatal"
# The PROPERTY is what matters, not which branch delivered it: the oversized payload
# must never ride into a single argv, and the reviewer must be told to fetch it.
if [ "$(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ')" -lt 110001 ]; then rc=0; else rc=1; fi
ck $rc "…the prompt stays inside the single-argv budget ($(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ') bytes, Linux caps one argument at 131,071)"
case "$(cat "$TMP/pi-prompt.txt")" in
  *"fetch the whole thing yourself"*|*"NOT inlined"*) rc=0;;
  *) rc=1;;
esac; ck $rc "…and it tells the reviewer to FETCH the diff instead of carrying it"
if [ "$(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ')" -gt 190000 ]; then rc=1; else rc=0; fi
ck $rc "…so the 200 KB payload is not in the prompt at all"
# The BYTE-budget branch (PROMPT_MAX) is only reachable when the CAP'd diff is multi-byte:
# 60,000 characters of a 3-byte character is ~180 KB. Without this arm the branch the PR
# calls "the single-argv fix" would be untested (P3, seventh fresh review).
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=60000; FIXTURE_DIFF_MULTIBYTE=1; FIXTURE_DIFF=""
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a MULTI-BYTE oversized diff still reviews (rc=$(rc_of))"
case "$(cat "$TMP/pi-prompt.txt")" in *"NOT inlined"*) rc=0;; *) rc=1;; esac
ck $rc "…via the no-diff re-compose branch (the PROMPT_MAX byte budget)"
if [ "$(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ')" -lt 110001 ]; then rc=0; else rc=1; fi
ck $rc "…and the re-composed prompt is inside the budget ($(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ') bytes)"

# ── §Q markdown list/table forms cannot hide a blocking finding from CLEAN ──
echo; echo "§Q a blocking finding in list/table markup still contradicts CLEAN"
for form in '+ [P1] scripts/x.sh:1 — plus-marker form' '1. [P1] scripts/x.sh:1 — ordered marker' '| [P1] | scripts/x.sh:1 | table row |' '### **[P1]** scripts/x.sh:1 — heading+bold'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  '${form%% *} …' => exit 7, no record (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
  no_comment; ck $? "  …and nothing posted"
done
# ⛔ AND A MID-LINE MENTION IS NOT A FINDING LINE (the other direction, and the one the
# fourth fresh review measured: its own CLEAN was refused because the sentence said
# "true of `[P1]` markup"). A guard that refuses every reviewer that explains itself is a
# new wall; both directions are pinned here.
for prose in 'No [P1] findings; I looked at every changed file.' 'true of `[P1]` markup, not of severity vocabulary' 'Priority 1 is handled by the adjacent guard'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a mid-line severity mention does NOT block: '${prose:0:34}…' (rc=$(rc_of))"
done
# …and the bare/bold/lowercase forms at the HEAD of a line DO (case-insensitivity too).
for form in '**P1** scripts/x.sh:1 — bold' 'P1 — bare' '[p1] lowercase bracket' 'P2: colon'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a line-leading '${form:0:20}…' refuses (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done

# ── §R a signed marker wins over an earlier unsigned one at the same head ───
echo; echo "§R an earlier UNSIGNED marker does not shadow the signed one"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
printf '\nreview recorded: reviews/2284.json verdict=clean @ %s (%s)\n' "$HEAD_FIXTURE" "$REPO_FIXTURE" >> "$TMP/body.md"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "records clean although an unsigned marker sits earlier in the body (rc=$(rc_of))"

# ── §S a reviewer that PRINTED clean but EXITED non-zero is not a verdict ───
echo; echo "§S CLEAN + non-zero exit => no verdict, no record"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_PI_RC=1
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "exit 6 (no verdict) although CLEAN was printed (rc=$(rc_of))"
err_has "exited rc=1"; ck $? "…naming the exit status as the cause"
no_comment; ck $? "no comment posted"
no_record; ck $? "NO record written — a crashed reviewer's leftover line is not a verdict"

# ── §T a warning on a SUCCESSFUL gh read is not a parse error ───────────────
echo; echo "§T a gh warning on a successful read is IGNORED, not a parse error"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
FIXTURE_GH_WARNING='warning: this graphql query is deprecated'
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "still reviews clean (rc=$(rc_of)) — the #2284 defect class, in the seam itself"
err_has "IGNORED"; ck $? "…the warning is surfaced as IGNORED, not swallowed"
[ -f "$TMP/record-argv.txt" ]; ck $? "…and the record was written"

# ── §U the reviewer CHILD gets the resolved repo, not an ambient one ────────
echo; echo "§U the reviewer child has GH_REPO PINNED to the resolved repo"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
GH_REPO="evil-org/evil-repo" run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "succeeds (rc=$(rc_of))"
grep -qx "GHREPO=$REPO_FIXTURE" "$TMP/pi-env.txt" 2>/dev/null; ck $? "the reviewer child ran with GH_REPO=$REPO_FIXTURE (a bare \`gh pr view\` inside it cannot read another repo)"

# ── §V an `ISSUES n` over ONLY P3 lines is clean — reconciled, never assumed ─
echo; echo "§V ISSUES 0 is clean; ISSUES n>0 is never converted to clean"
# ⛔ `ISSUES 0` is clean (zero blocking findings by the reviewer's own count); `ISSUES n>0`
# is NOT converted, however many of its lines parse as P3 — that heuristic was a fail-OPEN
# (a blocking finding in an unparsed form hid behind a matching count) and it is gone.
reset; printf 'Nothing blocks.\nISSUES 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "ISSUES 0 records clean (zero blocking findings by its own count) (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "…and the record IS written"
reset; printf '[P3] scripts/x.sh:1 — nit one\n[P3] scripts/x.sh:2 — nit two\nISSUES 2\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "ISSUES 2 over two P3s is NOT converted to clean (the contract says P3s ride under CLEAN) (rc=$(rc_of))"
err_has "reviewer-protocol slip"; ck $? "…and the slip is named"
no_record; ck $? "  …nothing recorded"
# the VERDICT line is parsed as widely as the severity lines
reset; printf 'I checked every changed file.\n**Verdict: CLEAN**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a decorated verdict line ('**Verdict: CLEAN**') parses (rc=$(rc_of))"
reset; printf 'Two blocking bugs.\nISSUES (2)\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and 'ISSUES (2)' parses as 2 blocking findings (rc=$(rc_of))"
# ⛔ A HEADING IS NOT A VERDICT (P1, eighth fresh review): `## Issues` used to match as
# `issues` with no count → ISSUES 0 → CLEAN, i.e. a transcript with NO verdict line could
# become a clean verdict. Both directions are pinned.
reset; printf '## Issues\n\nSome discussion with no verdict at all.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a '## Issues' HEADING with no verdict line is exit 6, never CLEAN (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'I read every hunk.\n**Verdict: ISSUES — 1 × P1, 2 × P3.** trailing prose\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…while a labelled verdict WITH trailing prose parses (rc=$(rc_of))"
# ⛔ THE VERDICT WORD IS THE FIRST ONE (P1, ninth fresh review): `*clean*` anywhere made
# `Verdict: ISSUES — … the code is not clean` record CLEAN.
reset; printf '**Verdict: ISSUES — 1 × P1.** This is not clean.\n[P1] scripts/x.sh:1 — bug\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "an ISSUES verdict whose prose says 'not clean' is NOT recorded clean (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# …and a decorated CLEAN with trailing prose still parses (it was rejected as NO VERDICT).
reset; printf 'Nothing blocks.\n**CLEAN — no blocking findings.**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "'**CLEAN — no blocking findings.**' parses as clean (rc=$(rc_of))"
# …while prose that merely STARTS with the word is not a verdict.
reset; printf 'Clean separation of concerns throughout.\n**CLEAN**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a prose line starting 'Clean separation…' is not mistaken for a verdict (rc=$(rc_of))"
# A severity SUMMARY table is counts, not findings.
reset; printf '| severity | count |\n|---|---|\n| P0 | 0 |\n| P1 | 0 |\n| P2 | 0 |\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a ZERO-count table (| P1 | 0 |) does not block a clean verdict (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written"
# ⛔ ONLY A ZERO COUNT IS A SUMMARY (P2, tenth fresh review): `| P1 | 2 |` under a CLEAN
# verdict says two blocking findings exist, and it must block.
reset; printf '| P0 | 0 |\n| P1 | 2 |\n| P2 | 0 |\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a NON-ZERO count row under CLEAN blocks (the table contradicts the verdict) (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# …and the reported count is the number AFTER 'ISSUES', not every digit on the line.
reset; printf '**Verdict: ISSUES — 1 × P1, 2 × P3.** done\n[P1] a.sh:1 — bug\n' > "$TMP/reviewer-out"
run "$SRC" 2284
err_has "1 blocking issue"; ck $? "the reported count is 1, not every digit on the verdict line"
case "$(cat "$TMP/err.txt")" in *1123*) rc=1;; *) rc=0;; esac; ck $rc "…and not a concatenation of the severity digits"
reset; printf '[P3] scripts/x.sh:1 — nit\n[P2] scripts/x.sh:2 — blocking\nISSUES 2\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…but a P2 among them still refuses (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf '[P3] scripts/x.sh:1 — nit\n[P3] scripts/x.sh:2 — nit\nISSUES 3\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and an UNRECONCILED count (ISSUES 3 over 2 parsed) refuses, fail-closed (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"

# ── §W the no-URL fallback names OUR comment or nothing ─────────────────────
echo; echo "§W no comment URL from gh => the fallback must match the body just posted"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_NO_URL=1
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "records clean when the newest comment IS the body just posted (rc=$(rc_of))"
err_has "verified by matching the body just posted"; ck $? "…saying how it was verified"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_NO_URL=1; FIXTURE_FOREIGN_BODY=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "refuses (exit 9) when the newest comment is SOMEONE ELSE'S (rc=$(rc_of))"
err_has "someone else"; ck $? "…naming the foreign artifact it refused to use"
no_record; ck $? "…nothing recorded"

# ── §K MUTATION — the clean-only guard is what makes §B pass ────────────────
echo; echo "§K mutation: remove the clean-only guard => §B's scenario must RECORD"
MUT="$TMP/mutant.sh"
cp "$SRC" "$MUT"; chmod +x "$MUT"
sed 's/^if \[ "\$KIND" != "clean" \]; then$/if false; then/' "$SRC" > "$MUT"
if cmp -s "$SRC" "$MUT"; then
  fail "the mutation did not apply — the anchored guard line changed shape, so this control proves NOTHING"
else
  pass "mutation applied (the clean-only guard replaced by an always-false test)"
  reset; printf '%s\nISSUES 2\n' "$FINDINGS_FIXTURE" > "$TMP/reviewer-out"
  run "$MUT" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT exits 0 on a findings verdict (proves §B's non-zero is the guard's doing)"
  [ -f "$TMP/record-argv.txt" ]; ck $? "the MUTANT RECORDS a findings verdict — so §B would FAIL without the guard"
  grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
  ck $? "…writing a false 'clean' record — exactly the fail-open §B exists to catch"
fi

echo
# Section-loss tripwire (see header): the count is a floor, not a coverage claim.
# ⛔ THE FLOOR IS CLOSE TO THE REAL COUNT ON PURPOSE (P3, tenth fresh review): at 120 against
# 144 assertions, deleting the LARGEST section (§Q, 23) still passed. At 140 every section but
# the very smallest deletion fires. It is still not a coverage claim, and a section smaller
# than (total - 140) is not caught by it.
# ⛔ IT RUNS BEFORE THE SUMMARY LINE (P3, fresh review of PR #2288): printing
# "RESULT: … 0 failed" and THEN failing on the pin reports a false-clean summary at the
# exact moment the tripwire is doing its job.
[ "$PASS" -ge 140 ]; ck $? "assertion-count pin: >= 140 assertions executed (section loss tripwire)"
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
