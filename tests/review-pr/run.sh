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
       FIXTURE_DIFF FIXTURE_ISSUE_URL FIXTURE_ISSUE_BODY FIXTURE_CID FIXTURE_AUTH_RC \
       FIXTURE_AUTH_MSG FIXTURE_PI_RC FIXTURE_MOVE_HEAD_TO FIXTURE_RECORD_RC
FINDINGS_FIXTURE='[P1] scripts/x.sh:42 — the guard returns 0 on a failed read — a red gate reports green
[P2] tests/y.sh:7 — the fixture would pass on the pre-fix code — vacuous'

# ── the fake gh: every read the script makes, and a record of HOW it was called ─
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Records the WHOLE argv and whether GH_REPO leaked into the environment, then
# answers the reads review-pr.sh makes. Fixtures come in through FIXTURE_*.
printf 'GHREPO=%s ARGV=%s\n' "${GH_REPO:-<unset>}" "$*" >> "$TMP/gh-calls.log"
cmd="${1:-}"; shift || true
case "$cmd" in
  auth) printf '%s\n' "${FIXTURE_AUTH_MSG:-Logged in to github.com}"; exit "${FIXTURE_AUTH_RC:-0}" ;;
  api)  printf '%s\n' "${FIXTURE_CID:-9001}"; exit 0 ;;
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
          body) printf '%s\n' "${FIXTURE_BODY:-fixture body}" ;;
          closingIssuesReferences) [ -n "${FIXTURE_ISSUE_URL:-}" ] && printf '%s\n' "$FIXTURE_ISSUE_URL"; ;;
          headRefOid) cat "$TMP/head" ;;
          *) echo "fake-gh: unhandled pr view --json $json" >&2; exit 1 ;;
        esac ;;
      diff) printf '%s\n' "${FIXTURE_DIFF:-diff --git a/x b/x}" ;;
      comment)
        cp "$body_file" "$TMP/comment.md" 2>/dev/null
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
exit "${FIXTURE_RECORD_RC:-0}"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/fake-pi" "$TMP/bin/fake-record"
export PATH="$TMP/bin:$PATH"

# reset <scenario> — one clean slate per scenario (fakes share $TMP, so state must go).
reset() {
  rm -f "$TMP/gh-calls.log" "$TMP/pi-argv.txt" "$TMP/pi-prompt.txt" "$TMP/pi-runs.txt" \
        "$TMP/record-argv.txt" "$TMP/comment.md" "$TMP/reviewer-out" "$TMP/rc"
  rm -rf "$TMP/home/.pi/agent/reviews"; mkdir -p "$TMP/home/.pi/agent/reviews"
  printf '%s\n' "$HEAD_FIXTURE" > "$TMP/head"
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
  HOME="$TMP/home" REVIEW_PR_PI="$TMP/bin/fake-pi" REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" \
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
grep -q 'Outcome: clean' "$TMP/comment.md" 2>/dev/null; ck $? "…and the comment states the outcome explicitly (record-review.sh's veto reads it)"
grep -q 'Non-blocking notes' "$TMP/comment.md" 2>/dev/null; ck $? "…carrying the reviewer's P3 note as a NON-BLOCKING note (clean = zero P0/P1/P2, the skill's own definition)"
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
err_has "self-contradicting"; ck $? "…naming the contradiction"
err_has "[P1] scripts/x.sh:42"; ck $? "…and printing the finding it refused to record over"
no_record; ck $? "NO record written"
no_record && [ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]; ck $? "…and no record file exists"

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
echo "================ RESULT: $PASS passed, $FAIL failed ================"
# Section-loss tripwire (see header): the count is a floor, not a coverage claim.
[ "$PASS" -ge 40 ]; ck $? "assertion-count pin: >= 40 assertions executed (section loss tripwire)"
[ "$FAIL" -eq 0 ]
