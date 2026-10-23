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
#   §K MUTATION: the clean-only guard removed => §B's scenario RECORDS, i.e. the
#      guard is what makes §B pass (a suite that only proves the happy path would
#      let a fail-open land green — the #2148/#1741 lesson).
#   §I an ambient GH_REPO       => cannot choose the repo; the url does
#   §J never edits a PR body    => source-level, non-comment lines
#   §M rc=0 without the PR-BODY marker (the artifact check (c) reads) => exit 9
#   §N an UNSIGNED marker => exit 9, the missing signing key named
#   §O a spawn-point load refusal (rc=76) => exit 75, nothing consumed
#   §P an oversized diff stays out of the single-argv prompt, with a fetch instruction
#   §Q a blocking finding in LIST/TABLE markup still contradicts CLEAN (§L is one form), a mid-line
#      bold label or a bare token naming a file:line still does, while a prose mention, a bold
#      sentence, a zero count, a bolded zero row and ANY P3 never do
#   §R an earlier unsigned marker does not shadow the signed one
#   §S the reviewer printed CLEAN but EXITED non-zero => no verdict, no record
#   §T a warning on a SUCCESSFUL gh read is ignored, not a parse error (the #2284 class)
#   §U the reviewer CHILD runs with GH_REPO pinned to the resolved repo
#   §V `ISSUES 0` is clean; `ISSUES n>0` is NEVER converted, even when every line parses P3
#   §W the no-URL comment fallback must match the body just posted, or refuse
#   §X recorder rc=0 with no record file on disk => exit 9
#   §Y a failed claim/issue read refuses (a failed read is not an empty value)
#   §Z a failed DIFF read that emitted partial bytes refuses
#   §AA an EMPTY --repo value is a usage error, never a silent fallback
#   §AB a prose line after a verdict cannot replace it; 'ISSUES: 2' parses
#   §AC the reviewed DIFF is re-verified (a base retarget with an unchanged head refuses)
#   §AD the marker must carry a signature field; an unsigned marker is named (HMAC = the gate's)
#   §AE MUTATION: the reviewer SPAWN removed => non-zero and NO record, and the staged
#      CLEAN verdict is never read ("no reviewer ran" cannot become an attestation)
#   §AF MUTATION: the moved-head guard removed => a verdict from head A lands an artifact at
#      head B ("an old verdict reused at a new head"), so §G's refusal is the guard's doing
#   §AG a blocking token the positional scan cannot see (a noun-prefixed `[P1]`), a hyphenated
#      `Verdict: CLEAN-UP …` that is not a verdict, and the `### Verdict: CLEAN` heading form
#   §AH a BARE P1/P2 that carries a `path:line` AFTER it still contradicts CLEAN — in EVERY bridge
#      form (`in`/`at`/`:`/`,`/parenthetical/dash), the class two reviews filed (#2288) — while a bare
#      P3, a clock time after the token, and the pinned location-BEFORE clean twin stay non-blocking
#   §AI the existing-record check reads the record's OWN `repo` field: a foreign repo's legacy
#      `<PR>.json` at the same head cannot block, and a refusal names the file it READ
#   §AJ a COMPLETED review that quotes `[pi-gate] REFUSED` is not the gate's refusal (rc is the signal)
#   §AK the ISSUES COUNT accepts every separator the verdict SHAPE accepts (`ISSUES: 0` is clean),
#      and a count the reviewer PRINTED is never raised — the clamp defaults only an UNPARSED one
#   §AL a TRUNCATED inline diff must PROVE the reviewer read the rest: a missing or wrong `diff-tail:`
#      digest is refused (rc=3, nothing posted, nothing recorded) — including when the diff's final
#      line is SHORTER than the token (the case that silently disabled the handshake) — while an
#      untruncated diff needs no proof at all; the EXPECTED digest is never disclosed in the prompt,
#      a fenced quote of a severity line is quotation (not a finding), and the digest tool is
#      resolved by running it (`sha256sum`, falling back to `shasum -a 256`)
#   §AM an UNCOUNTED `ISSUES` verdict over findings the severity scan cannot label FAILS CLOSED
#      (`ISSUES` is never read as `ISSUES 0`), and a printed dash-count (`ISSUES — 2`) survives
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
       FIXTURE_MARKER_MISSING FIXTURE_NO_KEY FIXTURE_GH_WARNING FIXTURE_NO_URL FIXTURE_FOREIGN_BODY FIXTURE_API_ROW FIXTURE_DIFF_MULTIBYTE FIXTURE_READ_FAIL FIXTURE_NO_RECORD_FILE FIXTURE_FLIP_DIFF \
       FIXTURE_SIGN_KEY
# ⛔ THE BOX'S OWN SIGNING KEY MUST NOT LEAK IN (P3, fresh review of #2288): a lane runs with
# `AI_REVIEW_GATE_KEY` exported (that is how the real recorder signs), and an inherited key lets
# the fake recorder mint a real HMAC even when `run()` passes it NONE — so the suite could not
# tell "the parent held the key" (the precondition §U's ABSENT assertion rests on) from ambient
# luck, and deleting `AI_REVIEW_GATE_KEY=` from `run()` left all 423 assertions green. Every
# invocation of `run()` exports the fixture's key; this line makes that the ONLY source, so the
# recorder's signature proves what the fixture passed rather than what the box happened to have.
unset AI_REVIEW_GATE_KEY
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
            # ⛔ THE PRODUCTION SEPARATOR, NOT TAB (P2, fresh review of #2288): the SUT reads
            # the `--jq '… join("\u001f")'` shape, i.e. unit-separated fields. A tab fixture
            # drove a `*)` fallback arm that shipped code no longer has (and whose empty-field
            # collapse made the empty-url guard unreachable), so all 420 assertions covered a
            # path production never takes. This fixture is now byte-shaped like the real read.
            printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${FIXTURE_URL:-}" "$(cat "$TMP/head")" \
              "${FIXTURE_TITLE:-fixture title}" "${FIXTURE_STATE:-OPEN}" "${FIXTURE_BASE:-main}" ;;
          body) [ "${FIXTURE_READ_FAIL:-}" = "body" ] && { echo "HTTP 503" >&2; exit 1; }
                cat "$TMP/body.md" 2>/dev/null || printf '%s\n' "${FIXTURE_BODY:-fixture body}"
                exit 0 ;;
          closingIssuesReferences)
                [ "${FIXTURE_READ_FAIL:-}" = "issues" ] && { echo "HTTP 503" >&2; exit 1; }
                # An EMPTY list is rc=0 with no output, exactly as real `gh` answers — the
                # `[ -n … ] && printf` form returned 1 for an empty list, which the seam's
                # new unreadable-list guard correctly refused (found by looping a scenario).
                if [ -n "${FIXTURE_ISSUE_URL:-}" ]; then printf '%s\n' "$FIXTURE_ISSUE_URL"; fi
                exit 0 ;;
          headRefOid) cat "$TMP/head" ;;
          *) echo "fake-gh: unhandled pr view --json $json" >&2; exit 1 ;;
        esac ;;
      diff)
        [ "${FIXTURE_READ_FAIL:-}" = "diff" ] && { printf 'diff --git a/x b/x\n+PARTIAL ONLY\n'; exit 1; }
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
        fi
        [ -f "$TMP/diff-body" ] && cat "$TMP/diff-body"
        exit 0 ;;
      comment)
        # Each posted comment is kept UNDER ITS OWN NAME (the seam posts a notes comment
        # before the verdict comment), and the last one is also $TMP/comment.md.
        n=$(( $(cat "$TMP/comment-n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$TMP/comment-n"
        cp "$body_file" "$TMP/comment-$n.md" 2>/dev/null
        cp "$body_file" "$TMP/comment.md" 2>/dev/null
        # ⛔ A DISTINCT ID PER COMMENT (P2, fresh review of #2288): one constant id made the
        # evidence id INDISTINGUISHABLE from the notes comment id, so a mutant that recorded
        # the non-blocking notes as `--evidence` passed all 420 assertions — and
        # `record-review.sh`'s veto would accept that body (it states no `Outcome:` field and
        # matches no blocking marker). The notes body posting is the FIRST comment and the
        # verdict the SECOND, so their ids differ and §A can assert WHICH one was recorded.
        [ "${FIXTURE_NO_URL:-0}" = "1" ] && exit 0
        printf 'https://github.com/%s/pull/%s#issuecomment-%s\n' \
          "${FIXTURE_REPO:-$REPO_FIXTURE}" "$prnum" "$(( ${FIXTURE_CID:-9001} + n - 1 ))" ;;
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
# ⛔ THE REVIEWER'S CWD IS AN OBSERVABLE (P1, dogfood review of this very file): it used to inherit
# the caller's checkout while the prompt asserted there was none, so the record could certify a head
# whose context reads came from a different tree.
printf '%s\n' "$PWD" > "$TMP/pi-cwd.txt"
printf 'GHREPO=%s\n' "${GH_REPO:-<unset>}" >> "$TMP/pi-env.txt"
# ⛔ THE SIGNING SECRET IS AN OBSERVABLE TOO (P2, fresh review of #2288): the strip was
# unasserted, so deleting `env -u AI_REVIEW_GATE_KEY` from the spawn left the suite fully
# green — a guard that can be removed with no red check is not a guard. Written to its own
# line so §U can read it next to GHREPO.
printf 'GATEKEY=%s\n' "$(if [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then printf present; else printf absent; fi)" >> "$TMP/pi-env.txt"
# A BASE retarget during the review: the head sha is untouched, the three-dot diff is not.
[ "${FIXTURE_FLIP_DIFF:-0}" = "1" ] && printf 'diff --git a/x b/x\n+BASE RETARGETED\n' > "$TMP/diff-body"
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
# FIXTURE_NO_RECORD_FILE: rc=0 having written NOTHING — the "recorder returned 0 but the
# artifact is not there" arm has to be drivable, or that guard is untested (§X).
if [ "${FIXTURE_NO_RECORD_FILE:-0}" != "1" ]; then
  printf '{"pr":%s,"head_sha":"%s","mint":"fresh","evidence":"%s","verdict":"%s","repo":"%s","reviewed_at":"2026-10-21T00:00:00Z"}\n' \
    "$pr" "$sha" "$ev" "$verdict" "$repo" > "$HOME/.pi/agent/reviews/${owner}-${name}-${pr}.json"
fi
# The recorder's OTHER artifact: the marker it appends to the PR body (signed, unless
# the key is missing). check (c) reads THIS, not the JSON — so the fake must produce it
# for the seam's post-record verification to be exercised at all.
if [ "${FIXTURE_MARKER_MISSING:-0}" = "1" ] || [ "${FIXTURE_NO_RECORD_FILE:-0}" = "1" ]; then exit "${FIXTURE_RECORD_RC:-0}"; fi
marker="review recorded: reviews/$pr.json verdict=$verdict @ $sha ($repo)"
if [ "${FIXTURE_NO_KEY:-0}" = "1" ]; then
  # ⛔ THE UNSIGNED-MARKER ARM IS CHECKED FIRST (P3, freshest review of #2288): FIXTURE_SIGN_KEY is now
  # EXPORTED (it was not, which is why the real-HMAC branch below was dead), so keying this branch on
  # the key being present would sign even the scenario that needs NO signature and the seam's
  # unsigned-marker refusal could never be driven.
  printf '\n%s\n' "$marker" >> "$TMP/body.md"
elif [ -n "${AI_REVIEW_GATE_KEY:-}" ]; then
  # A REAL HMAC, exactly as record-review.sh computes it — signed with the SAME env var the real
  # recorder uses (`AI_REVIEW_GATE_KEY`), not with the fixture's own variable (P3, fresh review of
  # #2288: keying this on FIXTURE_SIGN_KEY meant the fixture could sign even when the seam passed
  # the recorder NO key, so deleting `AI_REVIEW_GATE_KEY=` from `run()` left the suite green while
  # §U still claimed "the PARENT held the key"). ⛔ THIS EXERCISES THE FIXTURE'S SIGNING, NOT THE
  # SEAM'S VERIFICATION (P3, freshest review of #2288): review-pr.sh performs NO HMAC verification
  # at all (declared residual, scripts/review-pr.sh:1160-1170) — it pins the marker's SHAPE, i.e. a
  # 64-hex `sig=` field — so §A/§AD cannot tell a real signature from any 64 hex characters.
  sig="$(printf '%s' "$marker" | openssl dgst -sha256 -hmac "$AI_REVIEW_GATE_KEY" | awk '{print $NF}')"
  # (the FIXTURE_BAD_SIG branch went with the dead key resolution it served: review-pr.sh no longer
  # reads the signing key at all — record-review.sh owns it — so a forged signature is not a case
  # this tool can see. Its fixture var was reset but never set by any scenario (P3, dogfood review).)
  printf '\n%s sig=%s\n' "$marker" "$sig" >> "$TMP/body.md"
else
  # shape-valid, UNVERIFIABLE here (no key on the box): the seam must say so, not claim "signed"
  printf '\n%s sig=%064d\n' "$marker" 0 >> "$TMP/body.md"
fi
exit "${FIXTURE_RECORD_RC:-0}"
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/fake-pi" "$TMP/bin/fake-record"
export PATH="$TMP/bin:$PATH"

# reset <scenario> — one clean slate per scenario (fakes share $TMP, so state must go).
reset() {
  rm -f "$TMP/gh-calls.log" "$TMP/pi-argv.txt" "$TMP/pi-prompt.txt" "$TMP/pi-runs.txt" "$TMP/pi-cwd.txt" \
        "$TMP/record-argv.txt" "$TMP/comment.md" "$TMP/comment-n" "$TMP"/comment-[0-9]*.md "$TMP/reviewer-out" "$TMP/rc" "$TMP/pi-env.txt" "$TMP/diff-body"
  rm -rf "$TMP/home/.pi/agent/reviews"; mkdir -p "$TMP/home/.pi/agent/reviews"
  printf '%s\n' "$HEAD_FIXTURE" > "$TMP/head"
  printf '%s\n' "This PR fixes the thing. Closes #1876." > "$TMP/body.md"
  FIXTURE_MARKER_MISSING=0; FIXTURE_NO_KEY=0; FIXTURE_DIFF_BYTES=""; FIXTURE_GH_WARNING=""
  FIXTURE_NO_URL=0; FIXTURE_FOREIGN_BODY=0; FIXTURE_API_ROW=""; FIXTURE_DIFF_MULTIBYTE=0
  FIXTURE_READ_FAIL=""; FIXTURE_NO_RECORD_FILE=0; FIXTURE_FLIP_DIFF=0
  # Every scenario signs with a FIXTURE key by default so the fake recorder writes a REAL HMAC (a
  # shape-valid 64-hex sig the seam can pin). ⛔ The seam does NOT verify the HMAC (declared residual,
  # scripts/review-pr.sh:1160) — it checks the marker is PRESENT and carries a `sig=` field of the
  # right shape. FIXTURE_NO_KEY=1 is the unsigned-marker arm, which the seam must refuse.
  FIXTURE_SIGN_KEY="fixture-signing-key"
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
    AI_REVIEW_GATE_KEY="${FIXTURE_SIGN_KEY:-}" \
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
  "2284 $HEAD_FIXTURE clean $want --evidence comment:9002" ]
ck $? "…with <PR> <reviewed-head> clean <repo-from-url> --evidence comment:<id> (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
# ⛔ WHICH comment it names is asserted, not just that it names one (P2, fresh review of
# #2288): the notes comment is posted first (id 9001) and the verdict second (id 9002), and
# the seam must record the VERDICT — a mutant recording the notes passed every other
# assertion while naming an artifact that explicitly says it is not the verdict.
case "$(cat "$TMP/record-argv.txt" 2>/dev/null)" in
  *"--evidence comment:9001"*) rc=1 ;;
  *"--evidence comment:9002"*) rc=0 ;;
esac
ck $rc "…and it names the VERDICT comment (9002), never the non-blocking notes comment (9001)"
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
# ⛔ THE GUARD, NAMED (P2, fresh review of #2288): the fixture used to emit TAB, so an empty
# url collapsed into URL=<head sha> and this scenario died on the url-SHAPE check instead —
# rc=3 for the wrong reason, and the empty-field guard was never executed by any assertion.
# With the production separator the empty field survives the split, so the refusal the operator
# reads is the one this guard emits.
err_has "gh returned an empty url"; ck $? "…refused BY THE EMPTY-URL GUARD (not by an accidental url-shape failure)"
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
# ⛔ A QUOTED VERDICT IS NOT A VERDICT (P1, fresh review of #2288). The scan took the last
# verdict-SHAPED line anywhere, so a transcript that QUOTED the clean form — this tool's own
# artifact text is literally `**Verdict:** CLEAN — no blocking findings.` — certified clean while
# the reviewer had concluded nothing (`I could not complete the deep pass.`). The fenced variant
# exited 0 and wrote a signed head-bound clean record; the same transcript without the quote exits
# 6. Both directions below, plus the indented-block form (the other way to quote).
reset; printf 'The PR already carries this from an earlier head:\n```\n**Verdict:** CLEAN — no blocking findings.\n```\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a verdict QUOTED inside a code fence is NOT a verdict (rc=$(rc_of))"
no_record; ck $? "  …NO record — a quotation is not an attestation"
no_comment; ck $? "  …and nothing posted"
reset; printf 'Quoting the earlier report:\n\n    **Verdict:** CLEAN — no blocking findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…and the INDENTED code-block form is not a verdict either (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'The PR carries this from an earlier head:\n```\n**Verdict:** CLEAN — no blocking findings.\n```\n**Verdict:** CLEAN — no blocking findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…while a REAL verdict after the quote still records (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …the record is written"
# ⛔ A TAB IS AN INDENT (P2, fresh review of #2288): a markdown indented code block is FOUR
# COLUMNS and a tab reaches the second stop, so the four-space fix left a `\t**Verdict:** CLEAN …`
# quotation working (rc 0, artifact posted, signed clean record) while the same line with four
# spaces exited 6. Pinned as an A/B pair so the next literal-form fix cannot regress the other.
reset; printf 'Quoting the earlier report:\n\n\t**Verdict:** CLEAN — no blocking findings.\n\nCould not finish.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a TAB-indented quotation is not a verdict either (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
no_comment; ck $? "  …and nothing posted"
# ⛔ AN UNMATCHED MARKER MUST NOT RE-PAIR THE MARKERS AFTER IT (P1, fresh review of #2288). The
# first version of this rule dropped the LAST marker of an odd count, which re-pairs every marker
# after the unmatched one: `(unclosed ```diff)` … `(``` opening a quoted artifact)` `CLEAN`
# `(``` closing it)` has markers [2,6,8], so pairing (2,6) left the QUOTED `CLEAN` in no pair at all
# — rc 0, artifact posted, signed clean record, over a transcript whose author said it was not the
# verdict. Dropping the FIRST marker pairs (6,8) instead, the fail-closed direction.
reset; printf '# Quoting the diff I was shown:\n```diff\n- old line\n- another line\n# ...and the earlier artifact:\n```\n**Verdict:** CLEAN — no blocking findings.\n```\nThis is not my verdict.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "an UNMATCHED marker before a CLOSED quote does not expose the quote (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded — the quotation stayed a quotation"
no_comment; ck $? "  …and nothing posted"
# ⛔ POSITIONAL PAIRING IS WRONG IN TWO DIRECTIONS; BOTH ARE PINNED (P1, fresh review of #2288).
# (a) an unmatched marker LAST: dropping the first marker exposes what the first pair covered;
# (b) NESTING: a 4-backtick fence wrapping a 3-backtick block is the standard way to quote a
# markdown artifact that itself contains fences — adjacent pairing pairs across the nesting and
# treats the INNER block as prose. Both minted a signed clean record. The rule is now: group markers
# by fence SIGNATURE (character + run length) and take the UNION of both odd pairings, which can
# only skip MORE lines, so the worst case is exit 6 — never an attestation.
reset; printf 'Earlier head artifact:\n```\n**Verdict:** CLEAN — no blocking findings.\n```\nI could not complete the deep pass. Opening notes:\n```\nunfinished tail\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "(a) an unmatched marker LAST does not expose the earlier CLOSED quote (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'Quoting the hunk with a nested block:\n````md\n```\n**Verdict:** CLEAN — no blocking findings.\n```\n````\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "(b) a NESTED fence does not expose the inner block as the verdict (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# ⛔ THE CLOSER IS "SAME CHARACTER, RUN AT LEAST AS LONG", NOT "IDENTICAL SIGNATURE" (P1, fresh
# review of #2288). Exact-length grouping split a block whose closer was longer (or a different
# character) into single-marker groups, the odd-count union skipped nothing, and the QUOTED verdict
# became the verdict — rc 0, CLEAN artifact posted, signed clean record. Each shape below is
# pinned next to the matched-length control above.
for pair in '```|````' '````|```' '````|`````' '```|~~~'; do
  o="${pair%%|*}"; cl="${pair##*|}"
  reset; printf 'The diff I was shown opened with a fence I never closed:\n%s\n**Verdict:** CLEAN — no blocking findings.\n%s\nI did not finish the deep pass.\n' "$o" "$cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "6" ]; ck $? "…and an opener '$o' closed by '$cl' is still a quotation (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done
# …and one UNCLOSED opener above the quote: in markdown an unclosed fence runs to end-of-file, so
# the quotation is inside it — never the verdict.
reset; printf 'Opened a fence and never closed it:\n```\n**Verdict:** CLEAN — no blocking findings.\nI did not finish the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…and ONE unclosed opener above the quote swallows it (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# ⛔ THE TAIL OF AN ODD RUN IS FENCED TOO (P1, fresh review of #2288): the EOF span was added only
# when a marker had no relation in EITHER direction, so a marker that CLOSED an earlier fence and
# opened nothing of its own left the whole tail scanned as prose — and the quote after the LAST
# marker of an odd same-character run became the verdict (rc 0, artifact, signed record).
reset; printf 'The diff I was shown begins:\n```diff\ndiff --git a/x b/x\n+foo\n```\nThen it showed the earlier artifact text:\n```\n**Verdict:** CLEAN — no blocking findings.\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…and a quote AFTER the last marker of an odd run stays fenced (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
no_comment; ck $? "  …and nothing posted"
# ⛔ A FENCE MAY BE A LIST ITEM CONTENT (P2, fresh review of #2288): the matcher needed the run to
# begin the line, so `- ```` ` opened nothing while its closing marker still counted — unbalanced by
# construction, and the quoted verdict inside became the verdict. The control (opener on its own
# line) already refuses above.
reset; printf 'Quoting the earlier artifact:\n- ```\n  **Verdict:** CLEAN — no blocking findings.\n  ```\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…and a LIST-JOINED opener is a fence, not prose (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
no_comment; ck $? "  …and nothing posted"
# CONTROL for (b): the identical transcript without the 4-backtick wrapper IS a verdict — so the
# refusal above is the nesting rule and not the fixture refusing everything.
reset; printf 'Quoting the hunk:\n```\n**Verdict:** CLEAN — no blocking findings.\n```\nNothing else to add.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "  …while the same block WITHOUT the wrapper is still a quotation (rc=$(rc_of))"
reset; printf 'The hunk, then my verdict.\n```\n**Verdict:** CLEAN — no blocking findings.\n```\n**Verdict:** CLEAN — no blocking findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  …and a REAL verdict after a closed quote still records (rc=$(rc_of))"
# ⛔ THE COUNT GRAMMAR MUST ALSO BE A FINDING GRAMMAR (P2, fresh review of #2288): the count
# extractor reads `2 × P1` as the verdict's own count (§AM), while the severity cross-check had no
# cue for it at all — so `Blocking: 2 × P1` followed by `CLEAN` recorded clean. The one check
# that exists to refuse a self-contradicting verdict could not see the contradiction written in
# the tool's OWN count syntax: the two-grammars drift MEMORY.md records for `VD_ISSUES`, one over.
reset; printf 'Blocking: 2 × P1
CLEAN
' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "'Blocking: 2 × P1' contradicts CLEAN => refused (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'Summary: 0 × P3 notes, nothing blocking.
CLEAN
' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…while a ZERO-multiplier P3 summary stays clean (rc=$(rc_of))"

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
reset; printf 'diff-tail: %s\nCLEAN\n' "$(printf '%s\n' "$(head -c 200000 /dev/zero | tr '\0' 'x')" | sha256sum | cut -d' ' -f1)" > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""
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
# The arm is locale-dependent (${#DIFF} counts CHARACTERS only in a UTF-8 locale), so it runs
# under an explicit UTF-8 LC_ALL and SKIPS LOUDLY when the box has none — a C-locale runner
# reddening this suite would be a false signal (P3, eleventh fresh review).
UTF8_OK=""
for loc in C.UTF-8 en_US.UTF-8 UTF-8; do
  if [ "$(LC_ALL="$loc" bash -c 'x=→; printf %s "${#x}"' 2>/dev/null)" = "1" ]; then UTF8_OK="$loc"; break; fi
done
if [ -z "$UTF8_OK" ]; then
  fail "PROMPT_MAX re-compose arm SKIPPED: this box has no UTF-8 locale, so a multi-byte diff cannot be built (the branch is untested here)"
else
reset; printf 'diff-tail: %s\nCLEAN\n' "$(printf '%s\n' "$(awk 'BEGIN { for (i = 0; i < 60000; i++) printf "\342\206\222" }')" | sha256sum | cut -d' ' -f1)" > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=60000; FIXTURE_DIFF_MULTIBYTE=1; FIXTURE_DIFF=""
LC_ALL="$UTF8_OK" run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a MULTI-BYTE oversized diff still reviews (rc=$(rc_of))"
case "$(cat "$TMP/pi-prompt.txt")" in *"NOT inlined"*) rc=0;; *) rc=1;; esac
ck $rc "…via the no-diff re-compose branch (the PROMPT_MAX byte budget)"
if [ "$(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ')" -lt 110001 ]; then rc=0; else rc=1; fi
ck $rc "…and the re-composed prompt is inside the budget ($(wc -c < "$TMP/pi-prompt.txt" | tr -d ' ') bytes)"
fi

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
# ⛔ AND A **BOLDED** TOKEN IS A FINDING WHEREVER IT SITS (P1, fresh review of the fix). Dropping the
# bare `**P1**` form to silence the prose refusal was a FAIL-OPEN: `- Severity: **P1** — …` and
# `Finding 2 (**P1**): …` report blockers that no line-leading scan can see, so CLEAN was recorded
# over them. And the one-regex replacement had no delimiter PARITY, so it refused a genuinely clean
# report that merely had a `[P1]` mention BETWEEN two unrelated bold spans — the wall, back again.
# The rule the shipped awk implements is "the bold span's CONTENT is a severity label"; both
# directions are pinned here so neither fix can be re-broken in isolation.
for form in '- Severity: **P1** — scripts/x.sh:12 — the guard returns 0 on a failed read' 'Finding 2 (**P1**): a.sh:3 — unsafe default' 'Bug __P2__ a.sh:4 — reaches production'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a mid-line BOLDED severity label '${form:0:26}…' still blocks CLEAN (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done
for prose in 'I found **no** [P1] issues, **nothing** blocking.' '**Note**: the token [P1] appears in the prompt; **confirmed**.' '**No P1 issues** in any changed file.'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a mention inside/between bold prose does NOT block: '${prose:0:30}…' (rc=$(rc_of))"
done
# ⛔ ROUND 3 of the same rule, and both directions again (fresh review of the awk fix). The
# punctuation that ends a label can sit INSIDE the span (`**P1:**`), a single literal `**` earlier
# on the line must not shift span parity, and a plain finding introduced by prose still names a
# location. All three were fail-opens in the first awk draft. And the counter-direction: `**P1**:
# none.` is a COUNT, `**No P1**` is prose, P3 NEVER blocks (the prompt puts P3 notes under CLEAN),
# and a bolded zero-count table row is still a summary.
for form in '- **P1:** a.sh:12 — the guard returns 0' '- **[P1]:** a.sh:12 — the guard returns 0' '`**` is the bold marker; **P1** scripts/x.sh:12 returns 0' '- Finding: [P1] scripts/x.sh:12 — the guard returns 0'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a reported blocker '${form:0:26}…' refuses CLEAN (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done
for prose in '**No P1**: none.' '**P0**: none.  **P1**: none.' '**Zero P0** findings.' '- **[P3]** — nit: naming' '**P3** — a non-blocking note' '| **P1** | 0 |'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a count/prose/P3 form does NOT block: '${prose:0:26}…' (rc=$(rc_of))"
done
# ⛔ ROUND 4 — a count summary is a COUNT SHAPE, not its first word (fresh review).
# `**P0**: none of the call sites validate the returned error` and `P1: nil pointer dereference` are
# DESCRIBED FINDINGS whose description merely BEGINS with `none`/`nil`; reading the first word as a
# zero count dropped them and recorded a CLEAN over a P0. The reverse direction is pinned too: a real
# count summary (`P1 findings: none`, `P0/P1 findings: none`, `**P1** findings: none`, `P1 count: 0`)
# must not refuse a clean record. And a finding still counts when its LOCATION is written in
# backticks, or when the token is bare after a label (`Severity: P1 — a.sh:12`).
for form in '**P0**: none of the call sites validate the returned error' 'P1: nil pointer dereference when the body is empty' 'P1: 0 tests fail' '- Finding: [P2] `tests/y.sh:7` — the fixture is vacuous' '- Severity: P1 — a.sh:12 — the guard returns 0'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a DESCRIBED blocker '${form:0:30}…' refuses CLEAN (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done
for prose in 'P1 findings: none' 'P0/P1 findings: none' 'P1 issues: 0' '**P1** findings: none' 'P1 count: 0' '**P0**: none.  **P1**: none.'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a COUNT summary does NOT block: '${prose:0:28}…' (rc=$(rc_of))"
done
# ⛔ ROUND 5 — an EMPTY remainder is not a zero count (fresh review, and the worst fail-open of the
# set): a reviewer that lists findings as bare labels (`**P1**` on its own line, then the file and
# the claim) had every label read as a `P1: none` summary, so `clean` was RECORDED over a P1/P2 list.
# The reverse direction is pinned too: a zero count that carries a GLOSS (`none (verified against the
# full diff)`, `0 — nothing blocking`, `| P1 | 0 | no blocking findings |`) is still a summary and
# must not refuse the record — a reviewer's closing summary is stable across re-runs, so refusing it
# is a paid loop. And a numbered findings TABLE (`| 1 | P1 | path:12 | …`) must still block.
reset; printf '**P1**\nscripts/x.sh:12 — the guard returns 0 on a failed read.\n\n**P2**\ntests/y.sh:7 — the fixture is vacuous.\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a bare \`**P1**\` label line is a FINDING, not a 'P1: none' count (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded (this is the fail-open that read an empty remainder as a count)"
reset; printf '| 1 | P1 | scripts/x.sh:12 | returns 0 |\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a numbered findings TABLE row ('| 1 | P1 | path:12 |') blocks (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
for prose in 'P0/P1: none (verified against the full diff).' 'P1 findings: none (I checked every changed file).' '**P1**: 0 (none found).' 'P1: 0 — nothing blocking.' '| P1 | 0 | no blocking findings |' 'No findings at scripts/x.sh:12; severity P2 would be over-calling.' 'No P0, P1 or P2 findings.' 'I found no P0, P1 or P2 issues in the changed files.' 'P0, P1 or P2 findings: none'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a QUALIFIED zero count does NOT block: '${prose:0:30}…' (rc=$(rc_of))"
done
# ⛔ ROUND 6 — the SHAPE rule replaced the label grammar (fresh review, the round that named the
# class): each earlier round negotiated ONE more literal form, so the fail-open reappeared one form
# over. `**Finding 1 (P1)**` (an ORDINAL inside the span), `Severity: P1` on a continuation line (no
# location on THAT line), and a label written in code style (`Severity: \`P1\``) were all invisible.
# The counter-direction that the same fix created — a heading-per-severity SUMMARY (`**P0**` then
# `none.`) and a comma/semicolon gloss (`P1: 0, nothing blocking`) — refused a clean record, i.e. the
# paid loop. Both directions are pinned here so neither can be re-broken alone.
for form in '- **Finding 1 (P1)**: scripts/x.sh:12 — the guard returns 0 on a failed read' '  Severity: P1 — this ships a red gate that reports green' '- Severity: `P1` — scripts/x.sh:12 — the guard returns 0'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a label in ANY shape '${form:0:28}…' blocks CLEAN (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done
reset; printf '**P0**\nnone.\n**P1**\nnone.\n**P2**\nnone.\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a heading-per-severity SUMMARY ('**P0**' then 'none.') does NOT block (rc=$(rc_of))"
for prose in 'P1: 0, nothing blocking' '**P2** — none, all clean' 'P1: 0; all clean'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a glossed zero count does NOT block: '${prose:0:28}…' (rc=$(rc_of))"
done
# ⛔ ROUND 8 — the exemption side is a grammar too, and it failed OPEN. `P0: none, P1: 1` and
# `| P0 | 0 | P1 | 2 |` were exempted whole (a summary line that itself states a NON-ZERO blocking
# count recorded clean), a bare `P1` after a separator with a `path:12` on the line was never
# considered a label at all, and a `note:` in the DESCRIPTION dropped a leading `P1 note: …`. Each is
# pinned below; the count-pair cases are the direction that silently ships.
for form in '| P0 | 0 | P1 | 2 |' 'P0: none, P1: 1 — the recorder is bypassed when the answer file is empty' 'P0: 0; P1: 2 blocking findings' '**P0**: 0, **P1**: 2 — the recorder is bypassed' '- The recorder can be bypassed when the answer file is empty (scripts/review-pr.sh:1105) — P1' '1. the recorder is bypassed when the answer file is empty — P1, scripts/review-pr.sh:1105' 'P1 note: the recorder is bypassed when the answer file is empty'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a summary that states a NON-ZERO count is a finding (rc=$(rc_of)): '${form:0:32}…'"
  no_record; ck $? "  …nothing recorded"
done
# ⛔ ROUND 7 — the CUE. A label ALONE is not evidence: `No [P1] findings; …` (clean) and
# `- Finding: [P1] …` (blocking) are structurally identical — decorated token, mid-line, no
# location — so the previous conjunction (label AND a location/slot/line-lead) missed every
# decorated label used mid-sentence, and a whole family of clean summaries that merely STATE the
# convention was refused. Both directions pinned here.
for form in '- Finding 2 (**P1**): the recorder is bypassed when the answer file is empty' '- Finding: [P1] the recorder is bypassed when the answer file is empty' '- Finding [P1] — nothing re-reads the head after the recorder runs'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a mid-line decorated label with NO location blocks (rc=$(rc_of)): '${form:0:30}…'"
  no_record; ck $? "  …nothing recorded"
done
for prose in 'Severity guide: P0 = data loss; P1 = false PASS; P2 = friction.' 'Per the contract: P0/P1/P2 block; P3 does not.' 'Summary: P0 none found, P1 none found, P2 none found.'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a line that only STATES the convention does NOT block (rc=$(rc_of)): '${prose:0:28}…'"
done
# ⛔ THE REVIEWER MUST NOT INHERIT THE CALLER'S CHECKOUT (P1, dogfood review of this very file).
# This suite runs FROM the checkout under review, which is exactly the dangerous case: a reviewer that
# inherits it reads a working tree that is not the reviewed head (a different branch, uncommitted
# edits) while the record binds both the head and the live diff hash. Its cwd must be a scratch
# directory, so the prompt's "you have no checkout" is true.
reset; printf '**Verdict**: CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a clean review run from the checkout's own directory still completes (rc=$(rc_of))"
case "$(cat "$TMP/pi-cwd.txt" 2>/dev/null)" in
  *review-pr-*) pass "the reviewer ran in a SCRATCH directory, not the caller's checkout" ;;
  *) fail "the reviewer ran in the CALLER's checkout ($(cat "$TMP/pi-cwd.txt" 2>/dev/null)) — a record could certify a head it did not read" ;;
esac


reset; printf '**Verdict**: CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "'**Verdict**: CLEAN' (bold on the word only) parses as a verdict (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written"
# ⛔ AND A SCANNER THAT CANNOT RUN IS NOT A CLEAN SCAN (exit 10, no record) — the one fail-open this
# change introduced and then fixed had no tripwire until here. The suite already puts `$TMP/bin`
# first on PATH, so a failing `awk` stub is all it takes; every other tool the script needs is real.
if [ -d "$TMP/bin" ]; then
  printf '#!/bin/sh\nexit 2\n' > "$TMP/bin/awk"; chmod +x "$TMP/bin/awk"
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "10" ]; ck $? "a FAILING scanner refuses with exit 10, never a silent clean (rc=$(rc_of))"
  no_record; ck $? "  …no record written on a scanner failure"
  err_has "SCANNER failed"; ck $? "  …and the failure is named, with the scanner's own rc"
  err_has "rc=2"; ck $? "  …the REAL rc (the negated-`\$?` bug reported 0)"
  no_comment; ck $? "  …and nothing was posted as a review artifact"
  rm -f "$TMP/bin/awk"
else
  fail "no \$TMP/bin on PATH — the scanner-failure arm cannot be driven"
fi

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
# ⛔ …AND DOES NOT GET THE SIGNING SECRET (P2, fresh review of #2288). The parent DOES hold it:
# `run()` exports AI_REVIEW_GATE_KEY and the fake recorder has to mint a signature, so a green
# record is the proof the key was present in the parent — which is what makes "absent" below
# the CHILD's doing rather than a fixture that never set it.
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the recorder ran"
# ⛔ SIGNED MEANS NON-ZERO (P3, fresh review of #2288): this line used to assert only that the
# argv file existed, which is equally true when the fake recorder took its no-key arm and wrote
# an all-zero `sig=`. The HMAC is what proves the PARENT held the key — which is the only thing
# that makes §U's "the child saw it ABSENT" a result rather than a fixture that never set it.
_record_sig="$(grep -o 'sig=[0-9a-f]\{64\}' "$TMP/body.md" 2>/dev/null | tail -1 | cut -d= -f2)"
[ -n "$_record_sig" ] && [ "$_record_sig" != "$(printf '%064d' 0)" ]
ck $? "  …and the record was SIGNED with a non-zero HMAC, so the PARENT held the key"
grep -qx 'GATEKEY=absent' "$TMP/pi-env.txt" 2>/dev/null; ck $? "  …while the reviewer child saw AI_REVIEW_GATE_KEY ABSENT (its stdout is pasted into a public comment)"

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

# ── §X rc=0 from the recorder with NO record file on disk ────────────────────
echo; echo "§X recorder rc=0 but no record file => exit 9 (the local half of the success claim)"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_NO_RECORD_FILE=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "exit 9 when the recorder returned 0 and wrote nothing (rc=$(rc_of))"
err_has "NO clean record bound to head"; ck $? "…naming the missing record, not the marker"

# ── §Y a FAILED claim/issue read is refused, not reviewed as empty ──────────
echo; echo "§Y an unreadable PR body or issue list refuses (a failed read is not an empty value)"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_READ_FAIL=body
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "unreadable PR BODY => exit 3 (rc=$(rc_of))"
err_has "could not READ the PR body"; ck $? "…naming the read failure"
no_reviewer; ck $? "no reviewer paid for"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_READ_FAIL=issues
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "unreadable linked-issue list => exit 3 (rc=$(rc_of))"
err_has "could not READ the linked-issue list"; ck $? "…naming the read failure"
no_record; ck $? "nothing recorded"

# ── §Z a failed diff read is refused even when it printed PARTIAL bytes ─────
echo; echo "§Z a FAILED diff read refuses, even with partial output"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_READ_FAIL=diff
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "exit 3 on a failed diff read that emitted partial bytes (rc=$(rc_of))"
err_has "partial diff"; ck $? "…naming the partial read"
no_reviewer; ck $? "  the reviewer was never paid for a partial diff"
no_record; ck $? "  nothing recorded"

# ── §AA an EMPTY --repo value is a usage error ──────────────────────────────
echo; echo "§AA an EMPTY --repo is refused (no silent fallback to the cwd's repo)"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284 --repo ""
[ "$(rc_of)" = "2" ]; ck $? "exit 2 for '--repo \"\"' (rc=$(rc_of))"
run "$SRC" 2284 --repo=
[ "$(rc_of)" = "2" ]; ck $? "exit 2 for '--repo=' (rc=$(rc_of))"
no_reviewer; ck $? "  no reviewer dispatched on either"

# ── §AB a prose line after an ISSUES verdict cannot override it ─────────────
echo; echo "§AB trailing prose cannot replace a verdict (the first candidate in the tail wins)"
reset; printf '[P3] scripts/x.sh:1 — nit\nISSUES 2\nClean-up: remove the dead helper in a follow-up.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a trailing 'Clean-up: …' line does not turn ISSUES 2 into clean (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# ⛔ THE VERDICT IS THE **LAST** ONE (P1, fourteenth review): taking the FIRST candidate let an
# early CLEAN shadow a final ISSUES 2 and record a clean verdict.
reset; printf 'CLEAN is what I hoped for.\nCLEAN\nMore work showed two bugs.\nISSUES 2\n[P1] a.sh:1 — x\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a FINAL ISSUES 2 wins over an earlier CLEAN line (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# ⛔ …AND ONLY A REAL VERDICT SHAPE QUALIFIES (P2, fourteenth review): an uppercase
# `CLEAN-UP:` note 6 lines after an `ISSUES 2` used to fall inside the window and win.
reset; printf 'ISSUES 2\n[P1] a.sh:1 — x\nfiller\nfiller\nfiller\nfiller\nfiller\nCLEAN-UP: remove the dead helper\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "an uppercase 'CLEAN-UP:' note is not a verdict, even far from ISSUES (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'All good.\n**CLEAN — no blocking findings.**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "an uppercase decorated CLEAN still parses (rc=$(rc_of))"
reset; printf 'Two bugs.\nISSUES: 2\n[P1] a.sh:1 — x\n[P2] b.sh:2 — y\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "'ISSUES: 2' (colon) parses and blocks (rc=$(rc_of))"

# ── §AC a BASE retarget with an unchanged head is refused ────────────────────
echo; echo "§AC the reviewed DIFF is re-verified, not just the head"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_FLIP_DIFF=1
run "$SRC" 2284
[ "$(rc_of)" = "8" ]; ck $? "exit 8 when the DIFF changed while the head did not (a base retarget) (rc=$(rc_of))"
err_has "DIFF CHANGED"; ck $? "…naming the diff, not the head"
no_record; ck $? "…nothing recorded"
no_comment; ck $? "…and nothing posted"

# ── §AD the marker must carry a SIGNATURE FIELD, and an unsigned one is named ─
echo; echo "§AD the signed-marker check is shape+signature-field, and unsigned is named (declared residual)"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_NO_KEY=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "an UNSIGNED marker is exit 9 (rc=$(rc_of))"
err_has "AI_REVIEW_GATE_KEY"; ck $? "…naming the missing key"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a signature-bearing marker bound to this head is accepted (rc=$(rc_of))"
out_has "The HMAC is verified by the gate, not here"; ck $? "…and the success line says it did not verify the HMAC (shape only)"

# ── §AE MUTATION — no SPAWN, no record: the staged verdict is never read ─────
echo; echo "§AE mutation: the reviewer SPAWN removed => non-zero and NO record; the staged verdict is never read"
# ⛔ THE WALL THIS SECTION EXISTS FOR (2026-10-22). The seam's entire value is that the
# record it mints was produced by a reviewer that ACTUALLY RAN at that head. Remove the
# spawn and there is no transcript to parse — so nothing can be certified, however clean a
# verdict is sitting next door.
# ⛔ WHAT THIS DOES *NOT* PROVE (P2, fifteenth review — the earlier wording overclaimed it):
# `scripts/review-pr.sh` has NO cache to read. `$TMP/reviewer-out` is the FAKE REVIEWER's
# stdout source, i.e. exactly the bytes a real `pi` would print, and the only path by which
# anything reaches the verdict parser is the reviewer's own log. So the honest claim is
# mechanical, and it is the one asserted: the staged verdict EXISTS, `pi` was NEVER
# executed, the log is therefore empty, and no record is written. The control arm below
# runs the same fixture through the shipped script, which DOES record — which is what makes
# the mutant's refusal the missing spawn's doing rather than the fixture's.
MUT_SPAWN="$TMP/mutant-nospawn.sh"
cp "$SRC" "$MUT_SPAWN"; chmod +x "$MUT_SPAWN"
sed 's|^run_reviewer "\$TIMEOUT" "\$LOG" "\$PROMPT"$|: > "$LOG"|' "$SRC" > "$MUT_SPAWN"
if cmp -s "$SRC" "$MUT_SPAWN"; then
  fail "the spawn mutation did not apply — the anchored call line changed shape, so this control proves NOTHING"
else
  pass "mutation applied (the reviewer spawn replaced by an empty log)"
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
  [ -s "$TMP/reviewer-out" ]; ck $? "a CLEAN verdict IS staged where the reviewer would have printed it (the fixture is really there)"
  run "$MUT_SPAWN" 2284
  no_reviewer; ck $? "the MUTANT spawned no reviewer at all (\`pi\` was never executed, so the staged verdict was never read)"
  [ "$(rc_of)" != "0" ]; ck $? "…and exits NON-ZERO even with that CLEAN verdict on disk (rc=$(rc_of))"
  [ "$(rc_of)" = "6" ]; ck $? "…specifically 6 (no verdict from a reviewer that ran), never 0"
  no_record; ck $? "NO record written — a verdict nobody produced is not an attestation"
  no_comment; ck $? "…and no review artifact was posted either"
  [ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]; ck $? "…so the record store is untouched"
  # CONTROL: the SAME staged verdict, through the SHIPPED script, DOES become a record —
  # so the mutant's refusal is the missing spawn's doing and not the fixture's.
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the UNMUTATED script records the same staged verdict (rc=$(rc_of)) — so the refusal above is the missing spawn"
  [ -f "$TMP/pi-runs.txt" ]; ck $? "…because it actually spawned the reviewer, which is the only reader of that verdict"
fi

# ── §AF MUTATION — an OLD verdict cannot reach a NEW head ───────────────────
echo; echo "§AF mutation: with the moved-head guard removed, a verdict from head A lands an artifact at head B"
# The other half of the same wall: a review is a statement about ONE revision. A lane that
# reviews head A and then pushes head B still HOLDS a clean verdict, and the artifact it
# posts would be ACCEPTED by record-review.sh's evidence arm against B (that arm's only
# time binding is `created_at >= head commit date`) — certifying code nobody read. §G
# proves the seam refuses it; this section mutates the guard AWAY and asserts the refusal
# is the guard's, not the fixture's.
MUT_MOVE="$TMP/mutant-oldverdict.sh"
cp "$SRC" "$MUT_MOVE"; chmod +x "$MUT_MOVE"
sed 's|^[[:space:]]*if \[ "\$HEAD_AFTER" != "\$HEAD" \]; then$|if false; then|' "$SRC" > "$MUT_MOVE"
if cmp -s "$SRC" "$MUT_MOVE"; then
  fail "the moved-head mutation did not apply — the anchored guard line changed shape, so this control proves NOTHING"
else
  pass "mutation applied (the moved-head guard replaced by an always-false test)"
  # (a) the shipped script: the head moves mid-review => refused, nothing posted.
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_MOVE_HEAD_TO="$HEAD2_FIXTURE"
  run "$SRC" 2284
  [ "$(rc_of)" = "8" ]; ck $? "the shipped script REFUSES a verdict captured before the move (rc=$(rc_of))"
  no_comment; ck $? "  …and posts NO artifact, so none exists that could be bound to the new head"
  no_record; ck $? "  …and records nothing"
  # (b) the mutant: the OLD verdict now rides past the guard, and an artifact lands while
  # the PR's head is HEAD2 — the fail-open the shipped guard prevents.
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_MOVE_HEAD_TO="$HEAD2_FIXTURE"
  run "$MUT_MOVE" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT exits 0 on a verdict captured before the move (rc=$(rc_of))"
  [ -f "$TMP/comment.md" ]; ck $? "the MUTANT POSTS a clean artifact while the PR's head is HEAD2 — exactly the artifact record-review.sh's evidence arm would accept for HEAD2"
  grep -q "$HEAD_FIXTURE" "$TMP/comment.md" 2>/dev/null
  ck $? "…an artifact whose body names the REVIEWED head, while the PR's live head is HEAD2"
  # ⛔ THE SECOND GUARD, and it is why this mutation is a defect and not a catastrophe: the
  # seam passes the REVIEWED sha to the recorder, never the live one, so even this mutant
  # cannot mint a record BOUND to HEAD2 — and `record-review.sh <PR> <HEAD2>` would be
  # refused by the recorder's own stale-sha guard (#2133). Defence in depth, not a licence
  # for the seam to stop checking: the artifact above is the input that guard cannot see.
  case "$(cat "$TMP/record-argv.txt" 2>/dev/null)" in
    "2284 $HEAD_FIXTURE clean "*) rc=0;; *) rc=1;;
  esac; ck $rc "…and the MUTANT's record call is still bound to the REVIEWED sha, never the live head"
fi

# ── §AG the CONTRADICTION gate sees a token the reading order hid (the filed P1) ──
echo; echo "§AG a blocking token after a noun, and a hyphenated 'CLEAN-UP' verdict"
# The fifteenth review filed these against the shipped script; this section is the pin.
# A reviewer that INTRODUCES a finding with a noun (`**Finding [P1]**: …`) put an alnum in
# front of the token, so the positional scan missed it and `CLEAN` was recorded over two
# reported blockers — a fail-open on the one chokepoint before the record, not a formatting
# nit. And `**Verdict: CLEAN-UP the dead helper**` matched the LABELLED form, so a line that
# never says the code is clean became the verdict (VD_CLEAN deliberately refuses hyphenated
# continuations; VD_LABEL did not).
reset; printf '**Finding [P1]**: a.sh:1 — the guard returns 0 on a failed read\n**Finding [P2]**: b.sh:2 — fixture is vacuous\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a noun-prefixed bracketed [P1]/[P2] under CLEAN is REFUSED (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf -- '- **Blocker [P1]**: c.sh:3 — reaches production\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and the same in a markdown list ('- **Blocker [P1]**') (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf '[P3] a.sh:1 — nit\n**Verdict: CLEAN-UP the dead helper in a follow-up.**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a hyphenated 'Verdict: CLEAN-UP …' is NOT a verdict (exit 6, not a clean record) (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# …while the HEADING form a model actually emits is a verdict (it used to be exit 6).
reset; printf 'Nothing blocks.\n### Verdict: CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a '### Verdict: CLEAN' heading parses as clean (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written"
# …and a ZERO-count table row is still a summary, not a finding, under the widened scan.
reset; printf '| P0 | 0 |\n| P1 | 0 |\n| P2 | 0 |\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a zero-count severity table still does not block CLEAN (rc=$(rc_of))"

# ── §AK the COUNT accepts every separator the verdict SHAPE already accepts ───
echo; echo "§AK the ISSUES count reads the separator VD_ISSUES accepts, and a printed ZERO stays zero"
# The fresh review of #2288 filed this as its one blocking issue. `VD_ISSUES` accepts
# `ISSUES: 2` (§AB pins the colon form as supported input), but the count extractor's
# character class carried only `(`, `[` and a space — so the colon form parsed NO count, fell
# through to the `N ×` arm, and the clamp there (`-gt 0 || ISSUE_N=1`) raised a legitimately
# parsed ZERO to 1. A reviewer reporting ZERO blocking findings (`ISSUES: 0`) therefore exited
# 7, recorded nothing, and posted an artifact asserting a blocking finding that did not exist —
# the paid-review-into-the-same-refusal loop this file exists to remove, committed by the CLEAN
# branch. Both halves are pinned, each with its counter-direction.
reset; printf 'Nothing blocks.\nISSUES: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "'ISSUES: 0' is CLEAN and records (rc=$(rc_of) — 7 before the fix)"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …the record is written"
reset; printf 'Nothing blocks.\n**Verdict: ISSUES — 0 × P1**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…'**Verdict: ISSUES — 0 × P1**' is CLEAN (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …the record is written"
reset; printf 'Nothing blocks.\n**Verdict: ISSUES: 0**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…'**Verdict: ISSUES: 0**' is CLEAN (rc=$(rc_of))"
reset; printf 'Nothing blocks.\nISSUES (0)\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and the already-supported 'ISSUES (0)' stays CLEAN (rc=$(rc_of))"
# COUNTER-DIRECTION: the separator fix must not ZERO a real count — the colon form still blocks,
# and it reports the number the reviewer PRINTED (it used to be raised to the default 1).
reset; printf 'Two blockers.\nISSUES: 2\n[P1] a.sh:1 — x\n[P2] b.sh:2 — y\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "'ISSUES: 2' over two findings still blocks (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
err_has "found 2 blocking issue(s)"; ck $? "  …reporting 2, not the raised default 1"
reset; printf 'Two blockers, no lines.\nISSUES: 2\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and 'ISSUES: 2' with NO finding lines still blocks (rc=$(rc_of))"
err_has "found 2 blocking issue(s)"; ck $? "  …reporting the count the reviewer printed"

# ── §AM an UNCOUNTED `ISSUES` fails CLOSED, and a dash-count survives ────────
echo; echo "§AM an UNCOUNTED 'ISSUES' is never read as 'ISSUES 0' (the severity scan is not the count)"
# The fresh review of #2288 filed this as a P1 in the fix that CLOSED §AK's P2, which is exactly
# why both directions are pinned. `grep -c .` PRINTS `0` when it matches nothing, so the
# "no count printed, fall back to the blocking-line count" arm could never be empty: a reviewer
# whose last line was `**Verdict: ISSUES**` over findings the severity scan cannot LABEL (a bullet
# list, prose) produced `ISSUES 0`, which the clean arm then converted — rc 0, a `Verdict: CLEAN`
# artifact, and a signed clean record for a revision its own reviewer had just called ISSUES.
# A count the reviewer PRINTED is a different thing from a count the scan FAILED to find, and the
# two are pinned separately: §AK is the printed-zero direction, this is the unparsed one.
reset; printf 'Found problems but did not label them.\n- scripts/x.sh:42 — unvalidated shell interpolation allows injection\n- scripts/y.sh:7 — the guard returns 0 on a failed read\n**Verdict: ISSUES**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "an UNCOUNTED 'ISSUES' over unlabelled findings FAILS CLOSED (rc=$(rc_of))"
no_record; ck $? "  …NO record — 'the scan saw nothing' is not 'the reviewer found nothing'"
err_has "found 1 blocking issue(s)"; ck $? "  …and it says 1, not the scan's 0"
reset; printf 'Two blockers.\n**Verdict: ISSUES — 2**\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a PRINTED dash-count ('ISSUES — 2') blocks (rc=$(rc_of))"
err_has "found 2 blocking issue(s)"; ck $? "  …reporting 2, not silently lowered to the scan's 0"
# ⛔ …AND THE SHAPE ITSELF MUST ACCEPT THE DASH FORM (P2, fresh review of #2288). The count
# reader and its comments name `ISSUES — 2` as the realistic closer, but `VD_ISSUES` accepted only
# `(`, `[` and `:` — so the BARE dash form was not verdict-shaped, the count reader was
# unreachable for it, and a reviewer closing with `ISSUES — 2` was answered "NO VERDICT" and told
# to re-run into the same refusal. The digits stay mandatory: `ISSUES —` is still no verdict.
reset; printf 'Two blockers.\nISSUES — 2\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "the BARE dash form 'ISSUES — 2' parses and blocks (rc=$(rc_of))"
err_has "found 2 blocking issue(s)"; ck $? "  …reporting its own count"
reset; printf 'Nothing blocks.\nISSUES — 0 × P1\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and the bare 'ISSUES — 0 × P1' is CLEAN (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …the record is written"
reset; printf 'Something.\nISSUES —\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…while 'ISSUES —' with NO count is still not a verdict (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'Problems.\nVerdict = ISSUES\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and the equals form 'Verdict = ISSUES' fails closed too (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# …while the PRINTED-zero direction §AK pins still records (§AK's first three scenarios).

# ── §AH the bare label that NAMES ITS LOCATION AFTER IT (the filed P1) ───────
echo; echo "§AH a bare P1 with a location after it cannot hide from CLEAN"
# The fresh review of #2288 filed this fail-open: `label()`'s bare-token arm only accepted a
# `path:line` when the token was PRECEDED by a dash/comma/bracket, and `leads()` needed the token at
# line start, so both shapes below exited 0 and minted a signed `clean` over a reported blocker —
# while the residual text claimed a location-bearing label was caught. This section is the pin.
reset; printf 'Found one P1 in scripts/x.sh:12 — the guard returns 0 on a failed read.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "'Found one P1 in scripts/x.sh:12' under CLEAN is REFUSED (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'Finding P1 at scripts/x.sh:12 — the early return skips validation.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and 'Finding P1 at scripts/x.sh:12' (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# The SECOND fresh review filed the rest of the class: the first arm listed the bridges it expected
# (`in|at|on` after a dash/bracket), so every other bridge was the same fail-open ONE FORM OVER —
# the ratchet this scanner's own comment warns about. The arm now keys on the DIRECTION (a
# `path:line` after the token), so the bridge alphabet cannot be the thing that decides.
for bridge in 'P1: scripts/x.sh:12 — the guard returns 0.' 'P1, in scripts/x.sh:12 — the guard returns 0.' 'P1 (see scripts/x.sh:12) — the guard returns 0.' 'P1 — scripts/x.sh:12 returns 0.'; do
  reset; printf 'Found one %s\nCLEAN\n' "$bridge" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "…and 'Found one $bridge' (rc=$(rc_of))"
done
# …while a bare P3 with a location stays a note: the P3 arm must not widen with it.
reset; printf 'P3 in scripts/x.sh:12 — a style nit.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a bare P3 with a location is still a note, not a blocker (rc=$(rc_of))"
# …and a remainder whose only `:digits` run has no PATH character (a clock time) is not a location,
# so the direction arm does not turn a sentence about a timestamp into a blocking finding.
reset; printf 'The result is P1 at 10:30 in the log.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a clock time after a bare P1 is not a location (rc=$(rc_of))"
# …and the pinned clean twin (location BEFORE the token) stays clean — the whole reason the arm
# keys on what follows the token rather than on the line merely containing a location.
reset; printf 'No findings at scripts/x.sh:12; severity P2 would be over-calling.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and the pinned clean twin still records (rc=$(rc_of))"
# ⛔ THE THIRD FRESH REVIEW'S P1 — A SLOT SEPARATOR RIGHT AFTER THE BARE TOKEN (P1, measured). Each
# shape below exited 0 and wrote a signed `clean` record over a reviewer that had just stated a
# blocker, because every arm needed a label NOUN before the token or a `path:line` after it and these
# have neither. A separator is a USE cue on its own now; §Q pins that the zero-count forms stay clean.
for sepshape in 'Found a P1: the guard returns 0 on a failed read.' 'Found a P1 — the guard returns 0 on a failed read.' 'One P1: the early return skips validation.'; do
  reset; printf '%s\nCLEAN\n' "$sepshape" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "…and '$sepshape' under CLEAN is REFUSED (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done
# …while a ZERO count after the same separator keeps its exemption — the counter-direction this arm
# must not break (the arm widens LABEL detection, and counts_only()/nittag() still run after it).
reset; printf 'P1: 0 — nothing blocking.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and 'P1: 0 — nothing blocking.' still records (rc=$(rc_of))"
# ⛔ THE FOURTH FRESH REVIEW'S P1 — ONLY THE FIRST BARE TOKEN USED TO BE EXAMINED. `label()` ran a
# single `match()`, so a blocking label LATER on the line was invisible to every arm and a CLEAN over
# it was recorded. The loop examines every token; a later label wins over an earlier mention.
for latelabel in 'No P2 problems found; P1: the guard returns 0 on a failed read.' 'The fixture is fine (P2 clean); P1: the guard returns 0 on a failed read.' 'Two [P1] blockers. P1: the guard returns 0 on a failed read.' 'The **[P1]** convention applies here; P1 — the guard returns 0 on a failed read.'; do
  reset; printf '%s\nCLEAN\n' "$latelabel" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "…and a LATER blocking label refuses: '${latelabel:0:40}…' (rc=$(rc_of))"
  no_record; ck $? "  …nothing recorded"
done

# ── §AI a FOREIGN repo's legacy record at the same PR number+head is not evidence ──
echo; echo "§AI the existing-record check reads the record's OWN repo field"
# `$LEGACY` (`<PR>.json`) is repo-blind. A fork's record at a coinciding number AND sha used to
# block every review of this PR with a false cause, and the same predicate is step 8's proof that
# THIS repo's record landed. Both directions are pinned here.
reset
printf '{"pr":2284,"head_sha":"%s","verdict":"clean","repo":"some-fork/agent-infra"}\n' "$HEAD_FIXTURE" \
  > "$TMP/home/.pi/agent/reviews/2284.json"
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a LEGACY record naming a FOREIGN repo does not block the review (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and this repo's own record is written"
reset
printf '{"pr":2284,"head_sha":"%s","verdict":"clean"}\n' "$HEAD_FIXTURE" \
  > "$TMP/home/.pi/agent/reviews/2284.json"
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "5" ]; ck $? "a LEGACY record with NO repo field is treated as this repo's (rc=$(rc_of))"
# The refusal must name a file that EXISTS: it used to print the repo-qualified path while the
# only matching file was the legacy one (the #2349 class — a refusal says what it read).
if err_has "reviews/2284.json"; then rc=0; else rc=1; fi
ck $rc "  …naming the record it actually READ (the legacy path)"
if err_has "daniel-ospina-agent-infra-2284.json"; then rc=1; else rc=0; fi
ck $rc "  …and not a repo-qualified path that is absent"
reset
printf '{"pr":2284,"head_sha":"%s","verdict":"clean","repo":"%s"}\n' "$HEAD_FIXTURE" "$REPO_FIXTURE" \
  > "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json"
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "5" ]; ck $? "…and THIS repo's qualified clean record at the head refuses (rc=$(rc_of))"

# ── §AJ a COMPLETED review that QUOTES the gate's refusal is not a gate refusal ──
echo; echo "§AJ a quoted '[pi-gate] REFUSED' line does not turn a paid review into a refusal"
# The arm matched the string anywhere in the log, so a reviewer reviewing the gate itself was told
# "the reviewer was NOT STARTED … nothing was paid for" and the lane re-ran into the same refusal.
reset; printf '[pi-gate] REFUSED load=141 ceiling=100 (quoted from spawn-gate.sh:651)\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a completed review quoting the refusal line records (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …the record is written"
# …and the REAL refusal signal (rc=76) is still §O's arm.

# ── §AL a TRUNCATED inline diff needs PROOF the reviewer read the rest ─────
echo; echo "§AL a truncated-diff review must prove it fetched the tail"
# The record binds the FULL diff hash while the prompt inlines only DIFF_CAP characters, so the
# reviewer's "I fetched the remainder" was an unverifiable claim and the attestation could assert
# more than the review covered (P1, fourth fresh review of #2288). The prompt demands the last 40
# characters of the full diff's final line; both failure directions are pinned, and nothing may be
# posted or recorded on either.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "a truncated diff with NO 'diff-tail:' proof is REFUSED (rc=$(rc_of))"
no_comment; ck $? "  …nothing posted (no artifact a lane could bind)"
no_record; ck $? "  …and nothing recorded"
reset; printf 'diff-tail: %064d\nCLEAN\n' 0 > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "…and a WRONG tail proof is REFUSED (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# ⛔ THE PROOF MUST NOT DEPEND ON THE TAIL LINE'S LENGTH (P1, fifth fresh review). bash returns the
# EMPTY string from `${s: -40}` when the line is shorter than 40, so a diff ending on a short line —
# this PR's own diff ends on an 18-character one — silently skipped the whole handshake while the
# code still looked like it enforced it. The token is a SHA-256 now: no length precondition, no
# whitespace to lose. Both directions are pinned with a SHORT final line.
reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "a truncated diff ending on a SHORT line still DEMANDS the proof (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
printf 'diff-tail: %s\nCLEAN\n' "$(printf '%s\n' '+[ "$FAIL" -eq 0 ]' | sha256sum | cut -d' ' -f1)" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and the correct SHORT-line digest records (rc=$(rc_of))"
# …while a diff that FITS needs no proof at all: the requirement is scoped to truncation, not to
# every review (a spurious demand would wall every small PR).
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…an untruncated diff still records WITHOUT any tail proof (rc=$(rc_of))"
# ⛔ THE PROMPT MUST NOT DISCLOSE THE VALUE IT IS CHECKING (P0, sixth fresh review). The first version
# interpolated the expected digest, so a reviewer that fetched NOTHING could echo its instruction line,
# pass the proof and mint a clean record — the exact false PASS the handshake exists to prevent. The
# prompt now states what to COMPUTE; the expected value is asserted absent from the prompt bytes.
reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
EXPECT_DIGEST="$(printf '%s\n' '+[ "$FAIL" -eq 0 ]' | sha256sum | cut -d' ' -f1)"
printf 'diff-tail: %s\nCLEAN\n' "$EXPECT_DIGEST" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "the computed digest is accepted (rc=$(rc_of))"
if grep -qF "$EXPECT_DIGEST" "$TMP/pi-prompt.txt"; then rc=1; else rc=0; fi
ck $rc "…and the expected digest appears NOWHERE in the reviewer prompt (it cannot be echoed)"
if grep -qF 'diff-tail:' "$TMP/pi-prompt.txt"; then rc=0; else rc=1; fi
ck $rc "…while the PROOF LINE ITSELF is still requested by name"
# …and a correct digest WRAPPED IN MARKUP is still correct: the extracted value is normalised to hex
# (P3, sixth fresh review), so a backticked digest is not misdiagnosed as 'a different change'.
reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
printf 'diff-tail: `%s`\nCLEAN\n' "$EXPECT_DIGEST" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a backticked correct digest is accepted (rc=$(rc_of))"
# ⛔ A FENCED QUOTE IS NOT A FINDING (P2, sixth fresh review): a clean review that quotes this tool own
# output contract, or reproduces a fixture, inside a ``` fence was read as a blocking finding and
# discarded with nothing posted — and a re-run tends to quote it again. Unquoted line-leading tokens
# still block (§Q pins that direction), so only the quoted case moves.
reset; printf 'Here is the contract I was given:\n```\n  [P0|P1|P2] <file>:<line> — <what is wrong> — <why it matters>\n[P1] scripts/x.sh:42 — the guard returns 0 on a failed read\n```\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a FENCED quote of a severity line does not contradict CLEAN (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the review is recorded"
reset; printf '```\n[P1] scripts/x.sh:42 — the guard returns 0 on a failed read\n```\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and a fenced-only severity line records too (rc=$(rc_of))"
# ⛔ AN UNCLOSED FENCE MUST NOT SWALLOW THE REST (fail-closed; VGATE caught the balancing bug before it
# shipped). A bare toggle made an unterminated fence skip every remaining line — and this scan is the
# ONLY source of BLOCKING_FINDINGS, so a reviewer who quoted a hunk and forgot the closing fence would
# have its own `[P1] …` silently dropped, recording a clean attestation over a stated blocker. With an
# ODD fence count the last marker is unmatched and opens nothing, so the tail is scanned as text.
# ⛔ THE REFUSAL CODE MOVED FROM 7 TO 6, AND THE ARM STILL PINS WHAT IT EXISTS FOR (fresh review of
# #2288, the verdict-scan fence rule). With an unclosed fence, markdown puts everything after the
# marker INSIDE it — so the `CLEAN` below is a QUOTATION, not a verdict, and the run refuses with
# exit 6 ("no verdict") instead of reaching the contradiction guard at 7 ("issues"). Both are
# refusals that record nothing; the finding scan is unchanged and still sees the `[P1]` (its own
# arms above this one drive it directly). What this arm must never allow is a RECORD, so that is
# what it asserts, plus the code, so the reason for the refusal cannot silently change class.
reset; printf 'Evaluated against this contract:\n```\n  [P0|P1|P2] <file>:<line> — x\n[P1] scripts/y.sh:99 — the guard returns 0 on a failed read\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "an UNCLOSED fence puts the CLEAN inside it => no verdict, exit 6 (rc=$(rc_of))"
[ "$(rc_of)" != "0" ]; ck $? "  …and the run REFUSES rather than recording (never rc 0)"
no_record; ck $? "  …nothing recorded"
no_comment; ck $? "  …and nothing posted"
# ⛔ THE DIGEST TOOL IS RESOLVED, NOT HARDCODED (P2, sixth fresh review): macOS ships no `sha256sum`,
# and this file is farmed there — so the token is resolved to whichever tool exists. Pinned by
# SHADOWING sha256sum with a failing stub (shasum still answers): the run must still record.
if command -v shasum >/dev/null 2>&1; then
  mkdir -p "$TMP/nosha"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/nosha/sha256sum"; chmod +x "$TMP/nosha/sha256sum"
  reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
  printf 'diff-tail: %s\nCLEAN\n' "$EXPECT_DIGEST" > "$TMP/reviewer-out"
  PATH="$TMP/nosha:$PATH" run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "a box without sha256sum still computes the proof via shasum (rc=$(rc_of))"
  if grep -qF 'shasum -a 256' "$TMP/pi-prompt.txt"; then rc=0; else rc=1; fi
  ck $rc "…and the prompt tells the reviewer the tool this box actually has"
else
  fail "shasum fallback arm SKIPPED: this box has no shasum, so the portable-digest path is untested here"
fi

# ── §K MUTATION — the clean-only guard is what makes §B pass ────────────────
echo; echo "§K mutation: remove the clean-only guard => §B's scenario must RECORD"
MUT="$TMP/mutant.sh"
cp "$SRC" "$MUT"; chmod +x "$MUT"
sed 's/^if \[ "\$VERDICT" != "clean" \]; then$/if false; then/' "$SRC" > "$MUT"
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
# 144 assertions, deleting the LARGEST section (§Q, 23) still passed. Re-set from a MEASURED total
# whenever sections are added — this is 365, measured after the sixth review's fixes: §AL also pins
# that the expected digest is ABSENT from the prompt (the P0: it was being echoed), that a fenced
# quote of a severity line does not contradict CLEAN, that a backticked digest still matches, and
# that a box without a working `sha256sum` still proves the tail via `shasum -a 256`. It carries the
# truncated-diff arms (a truncated diff ending on an 18-character line must still DEMAND the proof,
# and accept the correct digest), the `Two [P1] …; P1: …` decorated-plus-bare cases, the §AL tail
# proof (missing proof, wrong proof, and the untruncated control), the §AH later-label cases and
# the `No P0, P1 or P2 findings.` / `I found no P0, P1 or P2 issues …` clean summaries, on top of the
# §AH separator shapes (a bare `Found a P1: …` / `Found a P1 — …` / `One P1: …` under CLEAN, each
# plus its no-record arm, and the `P1: 0 — nothing blocking.` counter-direction), which were added
# on top of
# `path:line` AFTER it, in every bridge form — dash, colon, comma, parenthetical — plus the clock-time
# counter-direction), §AI (the record's own `repo` field) and §AJ (a quoted gate refusal
# is not a refusal), plus §Q's label-SHAPE
# assertions (any label form: ordinal-in-span, continuation-line slot, code-styled token), the
# heading-per-severity SUMMARY counter-direction, and the scanner-failure arm (§Q is by far the
# largest section, and the scanner arm is the only tripwire on the exit-10 fail-open).
# ⛔ ONE LESS THAN THE PRINTED TOTAL, AND THAT IS NOT A TYPO (P2, third fresh review): the pin's own
# `ck` runs AFTER this comparison, so on a fully green run PASS is 374 here and the RESULT line then
# prints 375. A floor equal to the printed total could never pass — a permanently red tripwire is
# worse than none.
# ⛔ IT RUNS BEFORE THE SUMMARY LINE (P3, fresh review of PR #2288): printing
# "RESULT: … 0 failed" and THEN failing on the pin reports a false-clean summary at the
# exact moment the tripwire is doing its job.
[ "$PASS" -ge 374 ]; ck $? "assertion-count pin: >= 374 assertions executed (section loss tripwire)"
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
