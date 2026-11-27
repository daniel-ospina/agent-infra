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
#   §A3 (#2572) the record is PINNED to the REVIEWED head: the recorder REFUSES a moved head and
#      NOTHING is minted (§A4 mutates the flag away and the SAME scenario poisons the store with a
#      `clean` at a head nobody read); the pin's TWO exit-3 refusals — "the head MOVED" versus
#      "could not verify the PR head" (a gh/API TRANSPORT failure) — are classified SEPARATELY, and a
#      widened predicate is shown taking the wrong arm on the unverifiable output; and the literals
#      both seams key on are asserted present in `record-review.sh`, so a producer reword turns CI
#      red instead of silently re-grading a refusal
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
#   §AO the prompt's own `diff-tail:` PRODUCER is extracted from the RENDERED prompt and RUN (a
#      MUTATION un-escapes `$0` and the producer stops yielding the digest); a verdict quoted inside
#      an HTML block (`<pre>`/`<code>`) is a quotation, never the verdict, including over an earlier
#      `ISSUES` (MUTATION: the arm made unfindable records the false clean); a verdict line that says
#      CLEAN **and** carries a non-zero ISSUES count is refused while a ZERO count still records; and
#      a reviewer whose output ends with no trailing newline still has its verdict read
#   §AN a numeral `0` immediately before a severity token is a ZERO CUE, not a reported finding (so
#      `CLEAN — 0 P1, 0 P2 findings.` records instead of refusing itself), while a later non-zero
#      count in the same line still blocks; and the `CLEAN — <prose>` separator is matched by a
#      NON-ALNUM class rather than a multibyte bracket expression, so the arm still fires under
#      `LC_ALL=C` (a bracket expression is a BYTE there) while `CLEAN-UP` stays prose in both locales
#   §AP a CLEAN that reports its own findings in WORDS (`1 blocking finding remains`) is a verdict of
#      convenience and is refused, while the zero report, the severity-labelled zero report
#      (`0 P1, 0 P2 findings`) and a REPAIRED one (`1 finding fixed`) still record; a `### CLEAN`
#      heading is a verdict spelling while `## CLEAN UP …` is not; a credential the reviewer printed
#      (a `GH_TOKEN` VALUE and a raw `ghp_…` SHAPE) never reaches the published comment, while the
#      finding around it survives; and SIGTERM to the seam takes the paid reviewer child with it
#      (no orphan, nothing recorded, nothing posted). Three of the four carry a MUTATION control.
#   §AQ (#2670) the CLEAN gate is a STRUCTURED MARKER, not English: a CLEAN whose marker reports
#      FINDINGS_BLOCKING: 7 is refused, a CLEAN with NO marker is refused (naming the required block),
#      a marker saying REVIEW_VERDICT: ISSUES or carrying no readable count is refused, a marker quoted
#      inside a fence is a quotation — while marker+0 RECORDS, including the harness reviewer's own
#      `CLEAN <comment-url>` shape that this file could not parse at all (PR #3781); the prompt carries
#      the contract it enforces; and MUTATION controls (gate removed => the markerless CLEAN records;
#      both marker shapes broken => rc=10 'the scan did not run', never a silent pass). ⛔ The marker is
#      anchored BY POSITION: a transcript that only RESTATES the contract block (no verdict line) is
#      exit 6, and so is a marker placed BEFORE the verdict — the presence of the block is not proof
#      that a reviewer concluded anything (P2 finding, measured at the first review of this change)
#
#   §BU (#4233) THE MARKER SUPPLIES AN **ISSUES** VERDICT — NEVER A CLEAN ONE. A reviewer that
#      concluded with `REVIEW_VERDICT: ISSUES` / `FINDINGS_BLOCKING: 3` and NO prose verdict line was
#      answered `no verdict — re-run` and its three named findings were discarded; a prose `CLEAN` over
#      the SAME block was answered `a self-contradicting CLEAN verdict`. One input shape, two names, and
#      neither printed what the parser had read. The marker now SUPPLIES the refusal direction (count
#      READABLE and > 0, count line at or after the verdict field) and still may never supply CLEAN
#      (`ISSUES` over a zero stays exit 6 — the #2670 grant-direction pin), with a MUTATION control
#      proving the arm is what reads it and a fence/quotation arm proving repetition is not a verdict.
#      The unparseable arm now prints every field it matched and refuses to prescribe a blind re-run.
#
#   §BK (#3987) the CLEAN ARTIFACT carries the MUTATION ATTRIBUTION block `record-review.sh`
#      demands: the reviewer's own section is extracted and published in the evidence comment, the
#      POSTED artifact is judged by the recorder's OWN predicate (`brief-gate.sh --mutation-missing`),
#      the prompt carries the canonical shape byte for byte, the docs-only `NO NEW ASSERTIONS:` class
#      records on that line alone, and a reviewer that omits the section is refused LOUDLY (exit 11,
#      nothing posted, nothing recorded) instead of posting a verdict the recorder will reject. Two
#      MUTATION controls: drop the extraction and the compliant transcript is refused; drop the
#      pre-post validation and the refused artifact IS posted, with the real parser confirming it.
#
#   §BL (#3987) WHAT THE PARSER ACCEPTS IS NOT EVIDENCE: the seam knows the text it handed out and the
#      bytes it is about to publish, so it refuses a paste-back of the contract's worked ROW fenced or
#      not, refuses the recorder's unconditional veto phrases BEFORE posting, and pins that veto mirror
#      byte-for-byte against `record-review.sh`. Both preflight refusals the validator adds are driven.
#
#   §BM (#3987) THE OTHER HALF OF THE CONTRACT: the worked `NO NEW ASSERTIONS:` EXEMPTION line is the
#      second paste-back door — the parser accepts a live copy of the harness's own example reason, so
#      a `clean` record could be minted on a reason about a docs-only diff. Refused by provenance at
#      the seam, with the mutant that records it proving the arm is what refuses and an AUTHORED
#      reason proving the arm refuses copies, not exemptions.
#
#   §BQ (#3987) PROVENANCE AT THE CELL, NOT AT THE ROW: the parser asks only for a header naming the
#      three columns plus one row of >= 3 cells, so a copy that APPENDS a cell, DROPS its last cell or
#      PREFIXES a word to the worked row is still accepted while a whole-row equality test never sees
#      it. The seam counts the canonical row's distinctive CELLS instead, and refuses the EXTENDED
#      exemption too — with authored controls proving both are provenance tests and the widened-arm
#      mutant proving the arm is what refuses.
#
#   §BS (#3987) THE EXEMPTION'S STATED LIMIT, MEASURED AND PINNED: an INTERIOR-EDITED copy of the
#      worked `NO NEW ASSERTIONS:` reason (a word deleted, the first word changed, a word substituted,
#      the opening dropped) or a TRUNCATED one RECORDS. That is the documented limit, not an
#      oversight: the only rules that would refuse those shapes also refuse the natural phrasing of
#      the SAME claim ("docs-only — the diff touches docs/ops/<this diff's file>.md"), which is a
#      false block on an honest docs-only review. Both directions are asserted here — the copies
#      record AND the honest phrasings record — so a future round cannot close the limit silently,
#      and cannot "close" it into a gate that refuses the honest sentence it exists beside.
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
# ⛔ THE FIXTURE'S DIGEST MUST RESOLVE LIKE THE SUT'S (P3, fresh review of #2288): macOS ships no
# `sha256sum`, so an unguarded one made every truncated-diff expectation an EMPTY digest there and
# those assertions inverted to red — while the SUT itself resolves the tool (`sha256sum`, else
# `shasum -a 256`, pinned by §AL). A fixture that hardcodes one of the two tests the box, not the
# seam. Same resolution order as the script, in one place.
fixture_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi;
}

[ -f "$SRC" ] || { echo "❌ no review-pr.sh at $SRC"; exit 2; }

# ── the verdict SHAPES, read from the seam (§AQ's fake reviewer needs them) ──────────────────
# ONLY the three shape constants — no functions, no logic: the assertion discipline here is that the
# script is RUN for real, never re-implemented. The marker block the fake reviewer appends has to
# appear exactly when the seam's own shapes say a verdict was reached, or the fixture becomes a
# second definition of "a verdict" that drifts one spelling over — the class this suite exists to
# catch. A shape that vanishes from the seam fails LOUDLY here instead of silently un-covering §AQ.
eval "$(grep -aE '^VD_(CLEAN|CLEAN_URL|ISSUES|LABEL)=' "$SRC")"
[ -n "${VD_CLEAN:-}" ] && [ -n "${VD_CLEAN_URL:-}" ] && [ -n "${VD_ISSUES:-}" ] && [ -n "${VD_LABEL:-}" ] \
  || { echo "❌ could not read VD_CLEAN/VD_CLEAN_URL/VD_ISSUES/VD_LABEL from $SRC"; exit 2; }
export VD_CLEAN VD_CLEAN_URL VD_ISSUES VD_LABEL

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
       FIXTURE_MARKER_MISSING FIXTURE_MARKER_DIFF FIXTURE_NO_KEY FIXTURE_GH_WARNING FIXTURE_NO_URL FIXTURE_FOREIGN_BODY FIXTURE_API_ROW FIXTURE_DIFF_MULTIBYTE FIXTURE_READ_FAIL FIXTURE_NO_RECORD_FILE FIXTURE_FLIP_DIFF \
       FIXTURE_SIGN_KEY FIXTURE_PI_SLEEP FIXTURE_COMMENT_RC FIXTURE_LIVE_HEAD_AT_RECORD FIXTURE_PIN_UNCHECKABLE \
       FIXTURE_NO_MARKER FIXTURE_MARKER_VERDICT FIXTURE_MARKER_COUNT \
       FIXTURE_NO_MUTATION FIXTURE_MUTATION_EXEMPT \
       FIXTURE_CC_TOKEN FIXTURE_CC_RC FIXTURE_CC_RECORDED FIXTURE_CC_LIVE FIXTURE_CC_STDERR \
       FIXTURE_RECOVER_RC FIXTURE_RECOVER_BODY_OUT \
       FIXTURE_CC_TOKEN_AFTER_RECOVER FIXTURE_CC_RC_AFTER_RECOVER
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
    # ⛔ THE WHOLE INVOCATION IS LOGGED (P3, fresh review of #2288): logging only `--repo` let a mutant
    # that dropped `--repo` from the META read stay green, because later calls (`gh pr view --json
    # body`, `gh pr diff`) pass the same flag and the log line looked identical. §A2 asserts the META
    # read's own full argv prefix instead, which no other call can reproduce.
    printf 'ARGV:pr %s %s %s\n' "$sub" "$prnum" "$*" >> "$TMP/pr-repo.log"
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
        # ⛔ AND WHAT WAS SERVED IS ALSO ON DISK (P2, tenth fresh review of #2288): the tail proof now
        # binds a PER-RUN NONCE, so a scenario cannot hardcode the digest any more — the fake reviewer
        # must compute it from the nonce in its own prompt and the tail of the diff it actually
        # fetched, which is what a real reviewer does. §AL drives both directions.
        {
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
        } > "$TMP/served-diff.txt"
        cat "$TMP/served-diff.txt"
        exit 0 ;;
      comment)
        # ⛔ A COMMENT POST CAN FAIL (P3, fresh review of #2288): this arm always SUCCEEDED, so the
        # seam's `E_RECORD "review comment post FAILED"` refusal — the first of the four cases the
        # header's exit-9 paragraph enumerates — was never executed, and deleting it kept the suite
        # green. A real gh refuses on rate limit, auth expiry, or a locked conversation.
        if [ "${FIXTURE_COMMENT_RC:-0}" != "0" ]; then
          echo "HTTP 403: Resource not accessible (fixture)" >&2
          exit "${FIXTURE_COMMENT_RC}"
        fi
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
# ⛔ A SLEEPING REVIEWER IS AN OBSERVABLE (P2, fresh review of PR #2288). The wall-clock cap, its
# SIGTERM/SIGKILL escalation and the `--timeout` floor had NO assertion behind them: the fixture
# could only set an EXIT CODE, nothing could make it hang, and `grep -c -- '--timeout'` in this
# file returned 0 — so deleting the cap left every assertion green while the command the lane
# brief tells landers to type could hold a cell forever. A cap that is never driven is not a guard.
if [ -n "${FIXTURE_PI_SLEEP:-}" ]; then
  # The probe line is written BEFORE the sleep: a run that is KILLED at the cap still leaves it,
  # so a scenario can tell "the cap fired" from "the fixture never started".
  printf 'sleeping %s\n' "$FIXTURE_PI_SLEEP" >> "$TMP/pi-slept.txt"
  sleep "$FIXTURE_PI_SLEEP"
fi
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
# ⛔ THE SPAWN-GATE LEDGER TAG IS AN OBSERVABLE TOO (P3, fresh review of #2288): the file's own
# comment calls an untagged refusal an observability defect and records that KIND was once mistagged
# with a VERDICT, yet nothing read KIND/TAG — deleting the export left every assertion green.
printf 'KIND=%s\nTAG=%s\n' "${KIND:-<unset>}" "${TAG:-<unset>}" >> "$TMP/pi-env.txt"
# A BASE retarget during the review: the head sha is untouched, the three-dot diff is not.
[ "${FIXTURE_FLIP_DIFF:-0}" = "1" ] && printf 'diff --git a/x b/x\n+BASE RETARGETED\n' > "$TMP/diff-body"
# A head move DURING the review (the caller must refuse to record it).
[ -n "${FIXTURE_MOVE_HEAD_TO:-}" ] && printf '%s\n' "$FIXTURE_MOVE_HEAD_TO" > "$TMP/head"
# ⛔ THE REVIEWER COMPUTES ITS PROOF FROM WHAT IT FETCHED (P2, tenth fresh review of #2288). The
# expected value is sha256(per-run nonce + full diff tail) and the nonce is in the prompt, so a
# scenario can no longer hardcode a digest: it writes `diff-tail: @TAILPROOF@` and this fake — the
# stand-in for a reviewer that DID fetch — mixes the nonce it was given with the tail the fake gh
# served. A stub that cannot compute leaves the placeholder in place, which the seam must refuse.
if [ -f "$TMP/reviewer-out" ] && grep -q '@TAILPROOF@' "$TMP/reviewer-out" 2>/dev/null; then
  nonce="$(sed -n 's/^[[:space:]]*run-nonce:[[:space:]]*//p' "$TMP/pi-prompt.txt" 2>/dev/null | tail -1 | tr -d ' \r')"
  tail_line="$(tr -d '\r' < "$TMP/served-diff.txt" 2>/dev/null | awk 'NF{last=$0} END{print last}')"
  proof="$(printf '%s%s' "$nonce" "$tail_line" | sha256sum 2>/dev/null | cut -d' ' -f1)"
  [ -n "$proof" ] || proof="$(printf '%s%s' "$nonce" "$tail_line" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"
  sed "s/@TAILPROOF@/$proof/g" "$TMP/reviewer-out" > "$TMP/reviewer-out.expanded" 2>/dev/null \
    && REVIEWER_SRC="$TMP/reviewer-out.expanded"
  REVIEWER_SRC="${REVIEWER_SRC:-$TMP/reviewer-out}"
else
  REVIEWER_SRC="$TMP/reviewer-out"
fi
# ── THE NON-VACUITY BLOCK (agent-infra#3987 / #3442) ──────────────────────────────────────────
# This fake stands in for a COMPLIANT reviewer, so a transcript that REACHED a verdict also carries
# the caller's required `## MUTATION ATTRIBUTION` section, printed immediately BEFORE the verdict line
# exactly as the prompt says — the same discipline as the marker block below. A transcript with no
# verdict-shaped line gets none (inventing one on a crashed review would un-cover the very refusal
# §BK measures), and two knobs drive the refusal arms the seam must own:
#   FIXTURE_NO_MUTATION=1     the reviewer OMITTED the section entirely (the mode-6 defect itself)
#   FIXTURE_MUTATION_EXEMPT=1 the docs-only spelling: `NO NEW ASSERTIONS: <why>` at column 0
if [ -z "${FIXTURE_NO_MUTATION:-}" ] && [ -f "${REVIEWER_SRC:-/nonexistent}" ]; then
  _vl_no="$(grep -anE "($VD_CLEAN)|($VD_CLEAN_URL)|($VD_ISSUES)|($VD_LABEL)" "$REVIEWER_SRC" 2>/dev/null | tail -1 | cut -d: -f1)"
  if [ -n "${_vl_no:-}" ]; then
    if [ "${FIXTURE_MUTATION_EXEMPT:-0}" = "1" ]; then
      # ⛔ THE EXEMPTION LINE IS THE SECOND DOOR, AND THIS FIXTURE USED TO STAND IN IT (agent-infra#3987,
      # measured at 3d14cdab5). It read `NO NEW ASSERTIONS: docs-only — the diff touches docs/ops/*.md and
      # adds no executable assertion.` — a NEAR-COPY of the contract's own worked exemption, differing by
      # one word. That is the same defect §BK's table row had before it was fixed: the suite's
      # "compliant reviewer" echoes the example the prompt hands out, so §BK asserted a paste-back as
      # GREEN and the seam's provenance arm (now §BM) could not see it. It authors its own reason now,
      # naming the files a docs-only change would actually touch in THIS repo.
      printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: the only edits are to docs/ops/self-healing-contract.md, which carries no executable assertion — the guard itself lives in scripts/review-pr.sh and its arms are in §BK/§BL/§BM.\n\n' > "$TMP/mutation-section.md"
    else
      # ⛔ THE ROW IS THE REVIEWER'S OWN, AND DELIBERATELY NOT A COPY OF THE CONTRACT'S WORKED
      # EXAMPLE (agent-infra#3987, P1 at a8767f401). It used to be a near-copy of the canonical
      # `scripts/x.sh:120` row — i.e. the suite's "compliant reviewer" pasted back the row the prompt
      # hands out, and §BK asserted that as GREEN. That is the paste-back the seam now refuses, so a
      # fixture built on it would have been asserting the false PASS. It names this suite's own new
      # assertion instead, which is what an honest reviewer writes.
      cat > "$TMP/mutation-section.md" <<'MUT'
## MUTATION ATTRIBUTION

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `tests/review-pr/run.sh:3487` — the paste-back arm refuses the contract's own row | `mv rows.txt` | `§BK paste-back` | `RED`, rc=11 |

MUT
    fi
    # Insert immediately BEFORE the last verdict-shaped line — the seam cuts the section there.
    {
      head -n $(( _vl_no - 1 )) "$REVIEWER_SRC"
      cat "$TMP/mutation-section.md"
      tail -n +"$_vl_no" "$REVIEWER_SRC"
    } > "$TMP/reviewer-out.nonvacuous" 2>/dev/null && REVIEWER_SRC="$TMP/reviewer-out.nonvacuous"
  fi
fi
cat "$REVIEWER_SRC" 2>/dev/null
# ── THE STRUCTURED VERDICT MARKER (issue #2670) ───────────────────────────────────────────────
# This fake stands in for a COMPLIANT reviewer, so a run that REACHED a verdict also prints the
# caller's required marker block — the same way it prints the `diff-tail:` proof only when there is
# a proof to print. A run that never concluded (crash, wall-clock cap, provider refusal, the load
# gate) printed no verdict-shaped line, so it emits NO marker either: that distinction is exactly
# what the seam has to make, and inventing a marker on a transcript that has no verdict would turn
# §F's "no verdict" scenario into a clean record. The block is DERIVED from the transcript's own
# last verdict-shaped line, so every pre-existing scenario stays a faithful reviewer, and three
# knobs drive the refusal arms: FIXTURE_NO_MARKER (absent), FIXTURE_MARKER_VERDICT,
# FIXTURE_MARKER_COUNT.
# The verdict SHAPES are read from the seam itself (`VD_CLEAN`/`VD_ISSUES`/`VD_LABEL`) rather than
# re-typed here: a fixture that re-implements the grammar becomes a SECOND, drifting definition of
# "a verdict" — the exact class this suite exists to catch — and every `ISSUES 0`, `### CLEAN` and
# `ISSUES —` scenario below depends on the fixture agreeing with the seam byte for byte.
if [ -z "${FIXTURE_NO_MARKER:-}" ] && [ -f "${REVIEWER_SRC:-/nonexistent}" ]; then
  _vl="$(grep -aE "($VD_CLEAN)|($VD_CLEAN_URL)|($VD_ISSUES)|($VD_LABEL)" "$REVIEWER_SRC" 2>/dev/null | tail -1)"
  if [ -n "${_vl:-}" ]; then
    # the verdict WORD is the first CLEAN/ISSUES on that line, exactly as the seam reads it
    _vw="$(printf '%s' "$_vl" | grep -oiE '(clean|issues)' | head -1 | tr 'A-Z' 'a-z')"
    case "$_vw" in
      issues)
        # a printed count IS the count (never invented) — `ISSUES 2`, `ISSUES: 2`, `ISSUES — 2 × P1`
        _n="$(printf '%s' "$_vl" | sed -n 's/.*[Ii][Ss][Ss][Uu][Ee][Ss][^0-9]*\([0-9][0-9]*\).*/\1/p')"
        _wc="${_n:-1}"
        # `ISSUES 0` IS clean by the contract's own definition (`n` counts BLOCKING findings), so a
        # compliant reviewer writes the marker that says so. Without this the seam's own
        # `ISSUES 0 => clean` conversion would meet a marker reading ISSUES and refuse itself — a
        # WALL, not a guard (and §V pins that conversion from the other side).
        [ "${_wc:-1}" = "0" ] && _vw=clean
        ;;
      *) _wc=0 ;;
    esac
    printf '\nREVIEW_VERDICT: %s\nFINDINGS_BLOCKING: %s\n' \
      "${FIXTURE_MARKER_VERDICT:-$(printf '%s' "$_vw" | tr 'a-z' 'A-Z')}" "${FIXTURE_MARKER_COUNT:-$_wc}"
  fi
fi
exit "${FIXTURE_PI_RC:-0}"
EOF

# ── the fake recorder: proves WHAT review-pr.sh asked record-review.sh to bind ─
cat > "$TMP/bin/fake-record" <<'EOF'
#!/usr/bin/env bash
# ⛔ THE READ-ONLY VERBS COME FIRST (agent-infra#4255). `review-pr.sh` now asks this recorder's
# OWN carry predicate (`--check-carry`, and `--recover-body` when the store has no record) BEFORE
# it pays for a review. A fixture that let those verbs fall through to the MINT path below would
# treat `--check-carry` as the PR number and write a record file named after the flag — poisoning
# the store the seam reads and turning every "nothing recorded" assertion into a lie. They are also
# deliberately NOT appended to record-argv.txt: `no_record()` and the `head -1` argv assertions use
# that file to mean "the recorder was asked to MINT", which a read-only question is not.
# Defaults reproduce the PRE-#4255 behaviour exactly (`fresh` / rc 1 → fall through to a review), so
# every pre-existing scenario keeps meaning what it meant; the new arms are opt-in knobs.
case "${1:-}" in
  --check-carry)
    # A ONE-SHOT ANSWER: once `--recover-body` has run, the store DOES hold a record, so the next
    # question must be answerable differently. That is the #2872 sequence `review-pr.sh` now walks
    # (norecord → rebuild from the signed body marker → ask again), and without this knob the arm
    # that walks it could not be driven at all.
    if [ -f "$TMP/recover-pr.txt" ] && [ -n "${FIXTURE_CC_TOKEN_AFTER_RECOVER:-}" ]; then
      _tok="$FIXTURE_CC_TOKEN_AFTER_RECOVER"; _rc="${FIXTURE_CC_RC_AFTER_RECOVER:-0}"
    else
      _tok="${FIXTURE_CC_TOKEN:-fresh}"; _rc="${FIXTURE_CC_RC:-1}"
    fi
    printf '%s\t%s\t%s\n' "$_tok" "${FIXTURE_CC_RECORDED:-0}" "${FIXTURE_CC_LIVE:-0}"
    [ -n "${FIXTURE_CC_STDERR:-}" ] && printf '%s\n' "$FIXTURE_CC_STDERR" >&2
    printf '%s\n' "${2:-}" >> "$TMP/check-carry-pr.txt"
    exit "$_rc" ;;
  --recover-body)
    printf '%s\n' "${2:-}" >> "$TMP/recover-pr.txt"
    [ -n "${FIXTURE_RECOVER_BODY_OUT:-}" ] && printf '%s\n' "$FIXTURE_RECOVER_BODY_OUT"
    exit "${FIXTURE_RECOVER_RC:-1}" ;;
esac
printf '%s\n' "$*" >> "$TMP/record-argv.txt"
pr="$1"; sha="$2"; verdict="$3"; repo="$4"; shift 4 || true
ev=""; pin=""
while [ "$#" -gt 0 ]; do case "$1" in
  --evidence) ev="${2:-}"; shift 2 ;;
  --expect-head) pin="${2:-}"; shift 2 ;;
  *) shift ;;
esac; done
# ⛔ #2572 — THE FIXTURE ENFORCES THE PIN, IT DOES NOT MERELY RECORD IT. A fixture that only checked
# its argv would prove the flag is PASSED; this proves it is the thing that REFUSES, which is the
# claim. `record-review.sh` exits 3, writes no record and posts no marker when the PR's live head is
# not the sha named by `--expect-head`, and it names BOTH shas on stderr — reproduced here verbatim
# enough that the seam's own divergence arm (which greps for the flag) is exercised for real.
# With NO pin the fixture does what the real recorder's #2982 carry arm does — re-binds the verdict to
# the LIVE head (a true statement about the PR head, and not an answer to "record this sha") — so the
# unpinned call MINTS a `clean` record at a head nobody reviewed. That is the harm §A4 measures.
if [ -n "${FIXTURE_LIVE_HEAD_AT_RECORD:-}" ] && [ "$pin" != "$FIXTURE_LIVE_HEAD_AT_RECORD" ]; then
  if [ -n "$pin" ]; then
    printf '\u26d4 --expect-head: the PR head is %s, NOT the %s you named — refusing to record (no record written, no marker posted).\n' \
      "$FIXTURE_LIVE_HEAD_AT_RECORD" "$pin" >&2
    exit 3
  fi
  sha="$FIXTURE_LIVE_HEAD_AT_RECORD"
fi
# ⛔ THE PIN'S SECOND EXIT-3 REFUSAL — `record-review.sh:3029` (P2, fresh review of PR #2988). When the
# recorder cannot READ the PR's live head at all (gh failing: 403 secondary rate limit, 5xx, expired
# token; the #784 population) it refuses with `could not verify the PR head against <pin>` — the head
# did NOT move, and the remedy is a RECORD retry, not a fresh PAID review. Both refusal arms name
# `--expect-head`, so a predicate keyed on the flag cannot tell them apart; this knob is what makes the
# distinction DRIVABLE. Faithful on the property that matters: it writes NOTHING (no record file, no
# body marker) and exits 3 — unlike `FIXTURE_RECORD_RC`, which does its work before exiting.
if [ "${FIXTURE_PIN_UNCHECKABLE:-0}" = "1" ]; then
  printf '\u26d4 --expect-head: could not verify the PR head against %s — refusing to record (no record written, no marker posted).\n' "${pin:-<none>}" >&2
  printf '   Resolved head: <unavailable: no $REPO, or gh missing/failing>. A pin exists only if it is checked.\n' >&2
  exit 3
fi
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
# ⛔ THE RECORD'S OWN diff= GROUP (P2, third fresh review of #2288): `record-review.sh` hashes the LIVE
# diff at record time, so a base retarget between the seam's DIFF_AFTER read and the recorder's own
# read mints a marker attesting a diff nobody reviewed — at the unchanged head, so check (c) stays
# green. The seam now compares the marker's own `diff=` to what it reviewed, which can only be driven
# if the fixture can WRITE that group (the real recorder always does).
if [ -n "${FIXTURE_MARKER_DIFF:-}" ]; then
  marker="review recorded: reviews/$pr.json verdict=$verdict @ $sha diff=$FIXTURE_MARKER_DIFF ($repo)"
fi
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
        "$TMP/record-argv.txt" "$TMP/comment.md" "$TMP/comment-n" "$TMP"/comment-[0-9]*.md "$TMP/reviewer-out" "$TMP/rc" "$TMP/pi-env.txt" "$TMP/diff-body" "$TMP/pr-repo.log" "$TMP/served-diff.txt" "$TMP/reviewer-out.expanded" "$TMP/pi-slept.txt"
  rm -rf "$TMP/home/.pi/agent/reviews"; mkdir -p "$TMP/home/.pi/agent/reviews"
  printf '%s\n' "$HEAD_FIXTURE" > "$TMP/head"
  printf '%s\n' "This PR fixes the thing. Closes #1876." > "$TMP/body.md"
  FIXTURE_MARKER_MISSING=0; FIXTURE_MARKER_DIFF=""; FIXTURE_NO_KEY=0; FIXTURE_DIFF_BYTES=""; FIXTURE_GH_WARNING=""
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
  FIXTURE_LIVE_HEAD_AT_RECORD=""
  FIXTURE_PIN_UNCHECKABLE=0
  FIXTURE_PI_SLEEP=""
  # the structured-verdict marker (issue #2670): absent by default means "derive it from the
  # transcript", which is what every scenario written before the marker contract expects.
  FIXTURE_NO_MARKER=""; FIXTURE_MARKER_VERDICT=""; FIXTURE_MARKER_COUNT=""
  # The NON-VACUITY block (agent-infra#3987): absent by default means a COMPLIANT reviewer, i.e. one
  # that prints the attribution section before its verdict line. The two knobs drive the refusal arms.
  FIXTURE_NO_MUTATION=""; FIXTURE_MUTATION_EXEMPT=0
  # The reviewer's model pair (agent-infra#2208/#3413): empty means "let the seam resolve its own
  # defaults", which is what every scenario except §A5 wants.
  FIXTURE_LANE_PROVIDER=""; FIXTURE_LANE_MODEL=""
  FIXTURE_COMMENT_RC=0
  # §BW (agent-infra#4255) — the carry-before-review knobs. EMPTY means "the recorder's read-only
  # verbs answer what the pre-#4255 recorder's absence would" (token `fresh` / rc 1), i.e. the seam
  # falls through to a review exactly as it did before the change.
  FIXTURE_CC_TOKEN=""; FIXTURE_CC_RC=""; FIXTURE_CC_RECORDED=""; FIXTURE_CC_LIVE=""
  FIXTURE_CC_STDERR=""; FIXTURE_RECOVER_RC=""; FIXTURE_RECOVER_BODY_OUT=""
  FIXTURE_CC_TOKEN_AFTER_RECOVER=""; FIXTURE_CC_RC_AFTER_RECOVER=""
  rm -f "$TMP/check-carry-pr.txt" "$TMP/recover-pr.txt"
  unset RECORDER_OVERRIDE GH_REPO RUN_LC_ALL REVIEW_PR_MIN_TIMEOUT REVIEW_PR_KILL_GRACE
}

# run <script> [args...] — drives the REAL script under the fakes.
# ⛔ RECORDER_OVERRIDE LETS A SCENARIO POINT THE PREFLIGHT AT SOMETHING ELSE (P2, fresh review of
# #2288): every other scenario hardwired the fake recorder, so the preflight that refuses a
# missing/non-executable recorder — the guard that stops a review being paid for when the record step
# cannot run — had NO assertion behind it, and deleting it left the suite green.
run() {
  local script="$1"; shift
  # ⛔ `AGENT_INFRA_PATH` IS PINNED TO THIS TREE (agent-infra#3987). The seam resolves
  # `brief-gate.sh` through the ladder `$AGENT_INFRA_PATH/scripts/orchestrator-harness` — the same
  # ladder `record-review.sh` uses — and the suite runs MUTANT copies of the script from `$TMP`,
  # where no sibling `orchestrator-harness/` exists. Inheriting the caller's `AGENT_INFRA_PATH` made
  # those scenarios depend on a box's HUB checkout (a different, possibly stale gate) or fail with
  # the not-found refusal when it was unset; pinning it here makes every scenario validate against
  # the tree under test, and no ambient value can change which gate answers.
  HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" \
    REVIEW_PR_RECORD_SH="${RECORDER_OVERRIDE:-$TMP/bin/fake-record}" \
    AGENT_INFRA_PATH="$ROOT" \
    AI_REVIEW_GATE_KEY="${FIXTURE_SIGN_KEY:-}" \
    REVIEW_PR_MIN_TIMEOUT="${REVIEW_PR_MIN_TIMEOUT-}" \
    REVIEW_PR_KILL_GRACE="${REVIEW_PR_KILL_GRACE-}" \
    PI_LANE_PROVIDER="${FIXTURE_LANE_PROVIDER-}" \
    PI_LANE_MODEL="${FIXTURE_LANE_MODEL-}" \
    LC_ALL="${RUN_LC_ALL-}" \
    bash "$script" "$@" > "$TMP/out.txt" 2> "$TMP/err.txt"
  echo $? > "$TMP/rc"
}
rc_of() { cat "$TMP/rc"; }
out_has() { case "$(cat "$TMP/out.txt")" in *"$1"*) return 0;; *) return 1;; esac; }
out_not_has() { case "$(cat "$TMP/out.txt")" in *"$1"*) return 1;; *) return 0;; esac; }
err_has() { case "$(cat "$TMP/err.txt")" in *"$1"*) return 0;; *) return 1;; esac; }
err_not_has() { case "$(cat "$TMP/err.txt")" in *"$1"*) return 1;; *) return 0;; esac; }
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
  "2284 $HEAD_FIXTURE clean $want --evidence comment:9002 --expect-head $HEAD_FIXTURE" ]
ck $? "…with <PR> <reviewed-head> clean <repo-from-url> --evidence comment:<id> --expect-head <reviewed-head> (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
# ⛔ WHICH comment it names is asserted, not just that it names one (P2, fresh review of
# #2288): the notes comment is posted first (id 9001) and the verdict second (id 9002), and
# the seam must record the VERDICT — a mutant recording the notes passed every other
# assertion while naming an artifact that explicitly says it is not the verdict.
case "$(cat "$TMP/record-argv.txt" 2>/dev/null)" in
  *"--evidence comment:9001"*) rc=1 ;;
  *"--evidence comment:9002"*) rc=0 ;;
  # ⛔ NO DEFAULT ARM LEFT `rc` UNSET (P3, fresh review of #2288): a recorded argv that matched
  # NEITHER arm (an empty `--evidence comment:`, or no recorder call at all) left `rc` unbound, and
  # the suite runs under `set -u`, so `ck $rc` died with "unbound variable" after 3 of §A's
  # assertions — every later section, including the §K/§AE/§AF mutation controls, never executed and
  # no RESULT line was printed. A mismatch is a FAILED assertion, never a dead suite.
  *) rc=1 ;;
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
# ⛔ THE PROMPT IS COMPOSED BY AN UNQUOTED HEREDOC, SO A BACKTICK SPAN IN IT IS COMMAND
# SUBSTITUTION (measured at 71207625d, and it is why this arm exists): the sentence below carried
# unescaped backticks, so `NO NEW ASSERTIONS:` ran as a COMMAND — the seam printed
# "NO: command not found" on its own stderr, and the clause VANISHED from the prompt the reviewer
# is graded on. Both spans are INSTRUCTIONS the reviewer is told to obey, so a mangled one is a
# prompt the reviewer cannot comply with, and nothing reported it: this suite stayed green through
# eleven rounds while the text was silently missing. Asserted on the RENDERED prompt (plus the
# seam's own stderr), so unescaping either span reddens these arms.
case "$P" in
  *'ALSO refuses a `NO NEW ASSERTIONS:` line that repeats the contract'*) rc=0;;
  *) rc=1;;
esac; ck $rc "…every backtick span in the prompt survives composition VERBATIM (an unescaped one is command substitution)"
case "$(cat "$TMP/err.txt" 2>/dev/null)" in
  *"command not found"*) rc=1;;
  *) rc=0;;
esac; ck $rc "…and composing the prompt executes no command from its own text (no 'command not found' on stderr)"
# ⛔ THE MODEL PAIR, DRIVEN — not grepped (P2-F of the #3413 review). This seam used to hardcode
# `--model deepseek-v4-flash`, a LEGACY alias that answers nothing on the box: the reviewer session
# came up, loaded every extension, and produced ZERO assistant turns while the seam exited 0 with no
# verdict — a gate failing in the one shape a gate must never fail in. `merge-one.sh`'s `run_agent`
# was fixed for exactly this (agent-infra#2208) and nothing pinned the sibling, so restoring the
# literal left the whole suite green. The assertion is on the ARGV THE REVIEWER ACTUALLY RECEIVED.
case "$(cat "$TMP/pi-argv.txt")" in
  *"--provider deepseek --model deepseek-flash"*) rc=0 ;;
  *) rc=1 ;;
esac
ck $rc "…spawned on the same resolved model pair as the lane (deepseek/deepseek-flash, agent-infra#2208/#3413) — got: $(cat "$TMP/pi-argv.txt")"
case "$(cat "$TMP/pi-argv.txt")" in
  *"deepseek-v4-flash"*) rc=1 ;;
  *) rc=0 ;;
esac
ck $rc "…and NOT the legacy alias deepseek-v4-flash (the pin that made the reviewer answer nothing)"

# ── §A5 the reviewer's model pair resolves from PI_LANE_* (the lane/reviewer invariant) ───────
# The pair is ENV-OVERRIDABLE BY DESIGN (agent-infra#2208), and the whole point of #3413's second
# commit is that the lane and its reviewer resolve the SAME two variables. A pin on the default
# alone would pass a seam that ignored the env entirely, so the override is driven too.
echo; echo "§A5 the reviewer's model pair resolves from the PI_LANE_* pair"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
FIXTURE_LANE_PROVIDER="zai"; FIXTURE_LANE_MODEL="qwen3.8-max"
run "$SRC" 2284
case "$(cat "$TMP/pi-argv.txt" 2>/dev/null)" in
  *"--provider zai --model qwen3.8-max"*) rc=0 ;;
  *) rc=1 ;;
esac
ck $rc "…a PI_LANE_* override reaches the reviewer's argv (got: $(cat "$TMP/pi-argv.txt" 2>/dev/null))"
case "$(cat "$TMP/comment.md" 2>/dev/null)" in
  *"zai/qwen3.8-max"*) rc=0 ;;
  *) rc=1 ;;
esac
ck $rc "…and the posted review comment names the RESOLVED pair, not a literal baked into the table"
FIXTURE_LANE_PROVIDER=""; FIXTURE_LANE_MODEL=""

# ── §A2 the RECORD step's own failure arms, and the --repo mode ───────────────
# ⛔ (P2, fresh review of #2288) THREE GUARDS HAD NO ASSERTION BEHIND THEM and each could be
# deleted with the suite fully green: the recorder's non-zero exit check, the recorder preflight
# ("everything that can fail for FREE fails HERE, before a review is paid for"), and `--repo`
# actually reaching gh. The first is the only thing between "the recorder failed" and the
# `✅ recorded clean` line — the false-success class this seam exists to prevent.
echo; echo "§A2 the record step's failure arms + --repo mode are driven"
# (1) --repo is passed THROUGH to gh (a lander outside the checkout is told to use it)
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284 --repo "$REPO_FIXTURE"
[ "$(rc_of)" = "0" ]; ck $? "--repo owner/name mode reviews clean (rc=$(rc_of))"
grep -q "^ARGV:pr view 2284 --repo $REPO_FIXTURE --json url,headRefOid" "$TMP/pr-repo.log" 2>/dev/null
ck $? "…and the META read itself carried --repo $REPO_FIXTURE (a dropped flag would resolve another repo's PR of the same number)"
# (2) the RECORDER said rc=1 => exit 9, and NO success is claimed
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_RECORD_RC=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "a recorder that exits 1 => exit 9, never success (rc=$(rc_of))"
out_not_has "recorded clean"; ck $? "…and the success line is NOT printed (the review was not recorded)"
err_has "record"; ck $? "…the failure is named on stderr"
# (3) the recorder is MISSING/NOT EXECUTABLE => refused BEFORE the review is paid for
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/not-executable"; chmod -x "$TMP/bin/not-executable"
RECORDER_OVERRIDE="$TMP/bin/not-executable" run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "a non-executable recorder => exit 9 (rc=$(rc_of))"
no_reviewer; ck $? "…and NO reviewer was spawned (nothing was paid for)"
no_record; ck $? "…and no record was attempted"

# ── §A3 #2572 — THE RECORD IS PINNED TO THE HEAD THAT WAS REVIEWED ───────────
# The seam's advertised guarantee ("a record bound to the head it actually reviewed") is only a
# guarantee if the ONE call that mints the record says which head that is. Without `--expect-head`
# the recorder is free to re-point the verdict at the PR's LIVE head through its #2982 carry arm —
# a true statement about the PR head, and not an answer to "record this sha" (tortoise#9492).
# ⛔ THE FIXTURE ENFORCES THE FLAG, so these arms drive the refusal itself and not just its argv:
# `FIXTURE_LIVE_HEAD_AT_RECORD` is the head the PR is at when the recorder runs, and the fake
# refuses (rc=3, naming both shas) unless the caller pinned exactly that. An UNPINNED call, by
# contrast, mints at the live head — the carry arm's real behaviour — which is the harm §A4 measures.
echo; echo "§A3 #2572 — the recorder is PINNED to the reviewed head, and a head that moved is REFUSED"
# one predicate, used by §A3 AND re-evaluated verbatim against the mutant in §A4: a mutation control
# that asserts a DIFFERENT thing from the assertion it claims to falsify proves nothing.
pin_asserted() { # <argv-file> -> 0 iff the recorder call carries --expect-head <the REVIEWED head>
  case "$(cat "$1" 2>/dev/null)" in *"--expect-head $HEAD_FIXTURE"*) return 0 ;; *) return 1 ;; esac
}
PIN_ASSERTION="the recorder call carries --expect-head <the REVIEWED head $HEAD_FIXTURE>"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a pinned call at an unchanged head still records (rc=$(rc_of))"
pin_asserted "$TMP/record-argv.txt"
ck $? "$PIN_ASSERTION (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
# (2) THE MOVED HEAD. The review read HEAD_FIXTURE; by the time the recorder runs the PR is at
# HEAD2_FIXTURE (the window between the §G re-read and the mint — §G covers the OTHER window, a move
# during the review, and refuses before anything is posted). The pin makes this a refusal, and the
# refusal has to name BOTH shas or the operator cannot tell a stale review from a recorder bug.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD2_FIXTURE"
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "a PR head that MOVED before the record => exit 9, never success (rc=$(rc_of))"
out_not_has "recorded clean"; ck $? "…and the success line is NOT printed"
err_has "MOVED between the review and the record"; ck $? "…the seam names WHEN it moved (not a generic 'the recorder failed rc=3')"
err_has "$HEAD_FIXTURE"; ck $? "…naming the REVIEWED sha ($HEAD_FIXTURE)"
err_has "$HEAD2_FIXTURE"; ck $? "…and the LIVE sha the recorder refused to bind ($HEAD2_FIXTURE) — BOTH shas"
[ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]
ck $? "…and NO record exists at all: the pin refuses BEFORE minting, so the store is never poisoned with a clean record at an unreviewed head"
# (3) THE RESIDUAL ARM: a recorder that fails WITHOUT naming either pin refusal must stay the
# GENERIC named failure. This is an anti-catch-all control, NOT evidence for the pin, and it says so:
# the pre-fix source (`[ "$REC_RC" -eq 0 ] || die … "record-review.sh FAILED rc=$REC_RC …"`) satisfies
# every assertion below, so it cannot distinguish fixed from unfixed code by itself. ⛔ What it does NOT
# show (the pre-PR comment claimed it did, P2 fresh review of PR #2988): `FIXTURE_RECORD_RC=3` writes
# the record AND the body marker BEFORE exiting, so "nothing written" is false for this shape — the
# real rc=3 arms write nothing, and §A3(2)/(4) are where that is asserted.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_RECORD_RC=3
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "a recorder that refuses (rc=3) => exit 9, never success (rc=$(rc_of))"
out_not_has "recorded clean"; ck $? "  …and no success line"
err_has "record-review.sh FAILED rc=3"; ck $? "  …and a refusal that names NEITHER pin arm stays the generic named failure (neither new arm is a catch-all)"
# (4) THE PIN'S SECOND REFUSAL IS NOT THE FIRST ONE (P2, fresh review of PR #2988). `record-review.sh`
# refuses `--expect-head` for TWO reasons that need OPPOSITE remedies, and both print the flag:
#   :2884 `the PR head is <live>, NOT the <pin> you named`  => it MOVED; a fresh review is owed
#   :3029 `could not verify the PR head against <pin>`      => it could not be CHECKED (gh/API down);
#                                                              the head did not move, RE-RUN THE RECORDER
# A predicate keyed on the flag's PRESENCE merges them and orders a second PAID review for a transport
# blip. This arm drives the producer's real second message end to end.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_PIN_UNCHECKABLE=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "an UNVERIFIABLE pin (recorder cannot read the live head) => exit 9 (rc=$(rc_of))"
out_not_has "recorded clean"; ck $? "  …and no success line"
err_has "could NOT CHECK the --expect-head pin"; ck $? "  …the seam names WHICH refusal it was (the pin could not be CHECKED)"
err_not_has "MOVED between the review and the record"; ck $? "  …and does NOT report it as a MOVED head (the flag-presence predicate's misdiagnosis)"
err_not_has "a fresh review is owed"; ck $? "  …so it does not order a fresh PAID review for a gh/API transport failure"
err_has "Retry the RECORD"; ck $? "  …the remedy it names is the RECORD retry (the actionable one)"
[ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]
ck $? "  …and NOTHING was minted — the recorder refused before writing a record"
# ⛔ THE INVERTED CONTROL (§A4's standard): re-evaluate the PRE-FIX predicate — the flag's presence,
# nothing more — against the SAME unverifiable output, by widening the shipped literal back to the
# flag name. It takes the MOVED arm, so the §A3(4) assertions above are what the discrimination buys,
# not a property of the scenario.
MUT_PRED="$TMP/mutant-widepredicate.sh"
sed "s|^PIN_MOVED_LIT='--expect-head: the PR head is '|PIN_MOVED_LIT='--expect-head'|" "$SRC" > "$MUT_PRED"; chmod +x "$MUT_PRED"
if cmp -s "$SRC" "$MUT_PRED"; then
  fail "the widened-predicate mutation did not apply — the literal no longer has the anchored shape, so this control proves NOTHING (update the sed anchor)"
else
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_PIN_UNCHECKABLE=1
  run "$MUT_PRED" 2284
  err_has "MOVED between the review and the record"
  ck $? "  …and the PRE-FIX predicate (flag presence only) DOES report the same output as MOVED — so the classification is what fixes it"
  err_not_has "could NOT CHECK the --expect-head pin"
  ck $? "  …naming no transport failure at all, and advising a fresh review the operator never owed"
fi
# (5) THE LITERALS ARE A CONTRACT WITH THE PRODUCER, AND A CONTRACT THAT IS CHECKED. Classifying a
# refusal by its words is only sound while those words are the producer's; a reword on EITHER side
# would silently re-grade every refusal (cause 2 back onto cause 1), which is the defect §A3(4)
# guards by EXECUTION and this arm guards by CONSTRUCTION. Both consumers declare the literals as
# `PIN_MOVED_LIT=` / `PIN_UNCHECKABLE_LIT=`; this reads them OUT of each file and asserts the producer
# still emits them.
PRODUCER="$ROOT/scripts/record-review.sh"
producer_names_literals() { # <consumer> <producer> -> 0 iff BOTH literals the consumer keys on are in the producer
  local c="$1" p="$2" ml ul
  ml="$(sed -n "s/^ *PIN_MOVED_LIT='\(.*\)'$/\1/p" "$c" 2>/dev/null | head -1)"
  ul="$(sed -n "s/^ *PIN_UNCHECKABLE_LIT='\(.*\)'$/\1/p" "$c" 2>/dev/null | head -1)"
  [ -n "$ml" ] && [ -n "$ul" ] || return 1
  grep -qF -- "$ml" "$p" 2>/dev/null && grep -qF -- "$ul" "$p" 2>/dev/null
}
for consumer in "$SRC" "$ROOT/scripts/orchestrator-harness/merge-one.sh"; do
  producer_names_literals "$consumer" "$PRODUCER"
  ck $? "$(basename "$consumer") keys on two literals that record-review.sh still emits (moved: '…the PR head is '; uncheckable: 'could not verify the PR head against')"
done
# …and the guard BITES: reword the producer's second refusal and the SAME predicate goes false, so a
# drift on either side is a RED build rather than a silent re-grading of every future refusal.
MUT_PRODUCER="$TMP/mutant-producer.sh"
sed 's|could not verify the PR head against|could not read the PR head for|' "$PRODUCER" > "$MUT_PRODUCER"
if cmp -s "$PRODUCER" "$MUT_PRODUCER"; then
  fail "the producer-reword mutation did not apply — `could not verify the PR head against` is no longer in record-review.sh, so this control proves NOTHING"
else
  producer_names_literals "$SRC" "$MUT_PRODUCER"
  [ $? -ne 0 ]; ck $? "  …a reworded producer makes the SAME predicate FALSE (the drift is caught, not absorbed)"
fi

# ── §A4 MUTATION — drop the pin and the SAME move mints a record at the unreviewed head ──
# ⛔ THIS IS THE WHOLE ISSUE, ONE LAYER UP: a suite whose pin assertion still passed with
# `--expect-head` deleted would be VACUOUS. The mutation is applied to a COPY of the shipped script
# and the §A3 predicate is re-evaluated against it, with the expectation INVERTED — so the assertion
# is shown FALSE on the mutant, in its own words, rather than asserted through a proxy.
echo; echo "§A4 mutation: without --expect-head the moved-head scenario MINTS a clean record at a head nobody reviewed"
MUT_PIN="$TMP/mutant-nopin.sh"
sed 's| --expect-head "\$HEAD"||' "$SRC" > "$MUT_PIN"; chmod +x "$MUT_PIN"
if cmp -s "$SRC" "$MUT_PIN"; then
  fail "the #2572 mutation did not apply — the recorder call no longer has the anchored shape, so this control proves NOTHING (update the sed anchor in §A4)"
else
  pass "mutation applied (\`--expect-head \"\$HEAD\"\` stripped from the recorder call)"
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD2_FIXTURE"
  run "$MUT_PIN" 2284
  if pin_asserted "$TMP/record-argv.txt"; then
    fail "❌ $PIN_ASSERTION — STILL TRUE with the flag removed: the assertion is VACUOUS, which is exactly the defect #2572 is about"
  else
    pass "…and the §A3 assertion is now FALSE, verbatim: ❌ $PIN_ASSERTION (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
  fi
  # THE HARM, not the argv. The mutant's seam still exits 9 (its post-record checks read the record
  # store and the body marker), but the POISONED ARTIFACT IS ALREADY WRITTEN: a `clean` record bound to
  # a head nobody reviewed, in the store the merge gate reads. Reporting failure is not the guarantee;
  # not minting is.
  grep -q "\"head_sha\":\"$HEAD2_FIXTURE\"" "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
  ck $? "  …and the MUTANT mints a clean record bound to the UNREVIEWED live head $HEAD2_FIXTURE — the poisoned artifact the pin prevents from existing at all"
  # CONTROL: the shipped script, same scenario, leaves the store untouched — so the mint above is the
  # missing flag's doing and not the fixture's (§A3(2) asserts the same thing next to the refusal).
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD2_FIXTURE"
  run "$SRC" 2284
  [ ! -f "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" ]
  ck $? "  the UNMUTATED script records NOTHING in the same scenario — so the pin is what closed it"
fi

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
# ⛔ A SOURCE GREP IS NOT THE INVARIANT (P3, fresh review of PR #2288): the fake `gh` already logs
# every argv to `$TMP/gh-calls.log`, so assert on what the tool ACTUALLY SENT. A body write spelled
# `gh api --method PATCH … -f body=@f` (or `-X "$M"`) sails past both `case` arms above while this
# section kept reporting clean.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a full clean run completes (rc=$(rc_of))"
if [ -f "$TMP/gh-calls.log" ] && grep -qE 'ARGV=pr[[:space:]]+edit' "$TMP/gh-calls.log"; then rc=1; else rc=0; fi
ck $rc "…and no 'gh pr edit' was ever SENT to gh"
if [ -f "$TMP/gh-calls.log" ] && grep -qE 'ARGV=api[[:space:]]+[^[:space:]]*repos/[^[:space:]]*/pulls/[0-9]+[[:space:]].*(--method[[:space:]=]+PATCH|-X[[:space:]]*PATCH)' "$TMP/gh-calls.log"; then rc=1; else rc=0; fi
ck $rc "…and the PR OBJECT was never PATCHed (the write that wipes a recorded marker)"

# ── §L a CLEAN verdict that contradicts its own blocking finding ─────────────
echo; echo "§L CLEAN that carries a blocking finding => refused (the verdict must agree with its lines)"
reset; printf '[P1] scripts/x.sh:42 — a real blocking bug\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "exit 7 when the verdict says CLEAN but a [P1] line is present (rc=$(rc_of))"
no_comment; ck $? "NO comment posted — the refusal runs BEFORE the artifact exists (a fail-closed check placed after the side effect fails open)"
err_has "self-contradicting"; ck $? "…naming the contradiction"
err_has "a blocking finding on a DIFFERENT line"; ck $? "…and naming WHICH contradiction: a blocking finding on a different line, not an unreconcilable read (§BV(5)'s arm keeps the mild sentence)"
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

# ── §O2 the spawn point's MEMORY refusal is not a reviewer crash either (agent-infra#2387) ──
# The shim exits PI_GATE_MEM_REFUSED for the same kind of event (a capacity refusal that consumed
# nothing) with a DIFFERENT remedy. Without its own arm that code fell into the rc!=0 branch, which
# names a crashed/killed reviewer and tells the operator to re-run back into the same memory floor.
# ⛔ THE CODE IS READ FROM THE SHIM, NOT SPELLED HERE. This arm has now been wrong twice for exactly
# that reason: the draft's 72 is `REPO_TARGET_REFUSED` (#2694) on main and its 73 is
# `AGENT_FORK_REFUSED` (#2293), so it exercised the repo-target and fork arms and would have gone
# GREEN on the collision; then the literal 82 met `KEY_GATE_REFUSED` (#3331) and the internal code
# moved to 84. A fixture that hardcodes the number under test cannot notice either.
_mem_gate_rc="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "${PI_GATE_MEM_REFUSED:-}"' _ \
  "$ROOT/scripts/orchestrator-harness/spawn-gate.sh" 2>/dev/null)"
# ⛔ AN EMPTY READ IS A RED, NOT A SILENT 84 (round-13 review of #3645, P2). This line used to be
# `[ -n "$_mem_gate_rc" ] || _mem_gate_rc=84` — the same silent-default derivation §O3 fixes a few lines
# below, failing the same way: rename `PI_GATE_MEM_REFUSED` in `spawn-gate.sh` and this arm keeps exercising
# 84 against a seam that now emits another code, and stays GREEN, because the fallback fed the FIXTURE
# instead of the declaration. So the read is ASSERTED first; the literal survives only to keep the section
# runnable once a reshape has already been counted and printed as a red (`ck` returns, it does not abort).
[ -n "$_mem_gate_rc" ]; ck $? "the MEMORY-gate code is READABLE from spawn-gate.sh's declaration (got '${_mem_gate_rc:-<none>}') — a reshape must red here, not fall back to a literal"
_mem_gate_rc="${_mem_gate_rc:-84}"
echo; echo "§O2 spawn-point MEMORY refusal (rc=$_mem_gate_rc) => exit 81, named as a capacity event"
reset; printf '' > "$TMP/reviewer-out"; FIXTURE_PI_RC="$_mem_gate_rc"
run "$SRC" 2284
[ "$(rc_of)" = "81" ]; ck $? "exit 81 (its own code) not 6/75 (reviewer failure / load) (rc=$(rc_of))"
err_has "NOT STARTED"; ck $? "…saying the reviewer never started"
err_has "MEMORY gate"; ck $? "…naming the MEMORY gate, not the load one (the load wording is not universal)"
err_has "Nothing was consumed"; ck $? "…and that nothing was paid for"
no_comment; ck $? "no comment posted"

# ── §O3 the spawn point's HELPER/SYNC refusal is not a reviewer crash either (agent-infra#3231) ──
# The spawn point exits `AGENT_HARNESS_SKEW_REFUSED` when the gate and the `capacity.sh` it consumes were
# not deployed together — nothing ran, nothing was paid for, and the remedy is a VERIFIED redeploy. Without
# its own arm that code fell into the rc!=0 branch, which names a crashed/killed reviewer and tells the
# operator to RE-RUN — straight back into a sync fault no re-run can clear.
# ⛔ WHAT THIS ARM DOES AND DOES NOT DO (round-2 review of #3645, P2 — the previous comment overstated it):
# the CODE comes out of `spawn-gate.sh`'s own declaration, so a collision that moves it reds here instead of
# passing silently. The REMEDY is a literal `deploy-harness.sh` substring assertion (`err_has`, below) — it is
# NOT read out of the harness, and no file here reads `deploy-harness.sh`. Both halves were mutation-checked:
# `exit 83` → `exit 1` reds the rc assertion; reverting the sentence to the retired `cp ... *.sh` glob reds the
# `deploy-harness.sh` and `err_not_has` assertions.
_skew_decl="$(sed -n 's/^AGENT_HARNESS_SKEW_REFUSED=\([0-9][0-9]*\)$/\1/p' \
  "$ROOT/scripts/orchestrator-harness/spawn-gate.sh" 2>/dev/null | head -1)"
# ⛔ A DERIVATION THAT SILENTLY DEFAULTS IS NOT A DERIVATION (round-3 review of #3645, P2 — measured). This
# block used to be `[ -n "$_skew_rc" ] || _skew_rc=83`, so a declaration the anchor cannot READ — `export
# AGENT_HARNESS_SKEW_REFUSED=84`, or the value with a trailing comment — fell through to the literal 83 and the
# whole arm stayed GREEN against a code that had moved. That is the fail-open the header of
# `spawn-gate.test.sh` records as measured for this very `^NAME=` anchor (the note about `grep`ping a
# declaration with an anchor it did not anticipate) — quoted, not line-numbered, for the reason this PR
# keeps re-learning. So the read is ASSERTED separately, and the literal fallback below runs ONLY AFTER that
# assertion has already RED. That distinction is the whole point, so state it exactly (round-11 review of
# #3645, P3 — the earlier wording claimed the value was "used verbatim" while `:-83` still stood on the next
# line): `ck` counts a red and RETURNS, it does not abort — this file is `set -uo pipefail`, with no `-e` — so
# §O3 still EXECUTES against the literal instead of the suite stopping at a reshape. The old silent default
# could buy a GREEN; this fallback can only ever FOLLOW a red that has already been counted and printed.
[ -n "$_skew_decl" ]; ck $? "the skew code is READABLE from spawn-gate.sh's declaration (got '${_skew_decl:-<none>}') — a reshape must red here, not fall back to a literal"
_skew_rc="${_skew_decl:-83}"
echo; echo "§O3 spawn-point HELPER/SYNC refusal (rc=$_skew_rc) => exit $_skew_rc, named as a harness fault"
reset; printf '' > "$TMP/reviewer-out"; FIXTURE_PI_RC="$_skew_rc"
run "$SRC" 2284
[ "$(rc_of)" = "$_skew_rc" ]; ck $? "exit $_skew_rc (its own code) not 6/75 and NOT the file's own rc=2 (rc=$(rc_of))"
err_has "NOT STARTED"; ck $? "…saying the reviewer never started"
err_has "HELPER/SYNC"; ck $? "…naming the HELPER/SYNC fault, not the load gate's wording"
err_has "deploy-harness.sh"; ck $? "…with the VERIFIED redeploy remedy #3508 kept, not the retired cp glob"
err_not_has 'cp scripts/orchestrator-harness/*.sh'; ck $? "…and NOT the retired depth-1 glob that leaves a partial deploy"
err_has "Nothing was consumed"; ck $? "…and that nothing was paid for"
no_record; ck $? "no record written"
no_comment; ck $? "no comment posted"

# ── §P a prompt too large for one argv drops the diff instead of dying ──────
echo; echo "§P an oversized diff never rides into one argv (truncated, with a fetch instruction)"
reset; printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""
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
# ⛔ THE TAIL BLOCK'S OWN BACKTICK SPAN IS SHELL-ACTIVE TOO (same class as §A's arm; second
# measured instance at 71207625d). `## MUTATION ATTRIBUTION` sat unescaped between backticks
# INSIDE the nested `$(if … cat <<TAIL)` command substitution, where a line beginning with `#` is a
# COMMENT — so it expanded to EMPTY, silently, with no error at all: the reviewer was told
# "IMMEDIATELY BEFORE your  section", and the heading it must place the digest before was gone.
# This arm runs in the TRUNCATED path because that is the only path that composes the block.
case "$(cat "$TMP/pi-prompt.txt")" in
  *'IMMEDIATELY BEFORE your `## MUTATION ATTRIBUTION` section'*) rc=0;;
  *) rc=1;;
esac; ck $rc "…and the TAIL block's backtick span survives too (a '#' line inside \$() is a comment: it vanished with no error)"
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
reset; printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF_BYTES=60000; FIXTURE_DIFF_MULTIBYTE=1; FIXTURE_DIFF=""
# ⛔ THE LOCALE MUST REACH THE SUT THROUGH THE HARNESS'S OWN SEAM (P2, third fresh review of #2288 —
# MEASURED: `LC_ALL=C.UTF-8 run …` proves nothing, because `run()` assigns `LC_ALL="${RUN_LC_ALL-}"`
# in its command prefix and OVERRIDES the caller — the SUT then ran in the C locale and this arm went
# red on any runner whose ambient LANG is not UTF-8, the exact false signal the arm exists to prevent.
# `RUN_LC_ALL` is the seam §AN already uses.
RUN_LC_ALL="$UTF8_OK" run "$SRC" 2284
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
# ⛔ ROUND 9 — THE GLOSS AND THE P3 NOTE ARE NOT END-OF-LINE (P0, ninth fresh review of #2288). Both
# exemption arms returned "summary" for the whole remainder, so a NON-ZERO blocking pair after them
# was never read: measured at 7261f57e these four forms recorded `clean` with a comment posted while
# the reviewer's own text stated two blockers. The fourth is the table form of the same mistake.
# The counter-direction stays pinned: a gloss or a P3 tail that states NO blocking pair is still a
# summary (a reviewer's closing line is stable across re-runs, and refusing it is a paid loop), and
# a gloss that only DESCRIBES a clean check names no label at all.
for form in 'P0: 0 — none. P1: 2 blockers.' 'P1: 0 (none), P2: 3 real bugs.' 'P2: 0, P3: 1 note, P1: 2' '| P0 | 0 | P3 | 1 | P1 | 1 |'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a non-zero pair AFTER a gloss/note segment blocks (rc=$(rc_of)): '${form:0:34}…'"
  no_record; ck $? "  …nothing recorded"
  [ ! -s "$TMP/posted" ] || ! grep -q 'Verdict:\*\* CLEAN' "$TMP/posted" 2>/dev/null; ck $? "  …and no clean artifact posted"
done
for prose in 'P0: 0 — none.' 'P1: 0 (verified against the full diff).' 'P1: 0 — nothing blocking.' 'P2: 0, P3: 12 nits.' 'P3: 4 nits.'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a gloss/note tail with NO blocking pair does NOT block: '${prose:0:30}…' (rc=$(rc_of))"
done
# ⛔ ROUND 10 — THE SEVERITY VOCABULARY (P2, tenth fresh review of #2288). The prompt and this repo
# own code-review skill name severity in WORDS, and the scanner only ever looked for `P<n>`: a
# findings report in the skill own vocabulary that closed `CLEAN` was certified clean — measured at
# the reviewed head for all four decorated forms below (rc 0, signed record, CLEAN artifact).
# The counter-direction is the reason the word is not matched bare: `Only HIGH-confidence issues` and
# `**High** confidence …` are clean summaries that USE the word without labelling a finding, and
# refusing them is the paid loop this tool exists to remove.
for form in '- [High] scripts/x.sh:12 — the guard returns 0 on a failed read' '- [Medium] tests/y.sh:7 — the fixture is vacuous' '- [Blocker] scripts/x.sh:12 — the guard returns 0' '- **[Critical]** scripts/x.sh:12 — the guard returns 0' '**High** — the guard returns 0 on a failed read' 'Severity: high — this ships a red gate that reports green' 'Priority: critical — the recorder is bypassed'; do
  reset; printf '%s\nCLEAN\n' "$form" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a SEVERITY-WORD finding blocks CLEAN (rc=$(rc_of)): '${form:0:34}…'"
  no_record; ck $? "  …nothing recorded"
done
for prose in 'Only HIGH-confidence, real issues were considered.' '**High** confidence that the flagged guard is sound.' 'Per the contract, severities are high, medium and low.' 'No [High] findings — I checked the changed files.' 'No significant findings; the high-risk path is covered.'; do
  reset; printf '%s\nCLEAN\n' "$prose" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  a clean summary that only USES a severity word does NOT block: '${prose:0:30}…' (rc=$(rc_of))"
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
  # ⛔ THE STUB MUST STILL COMPILE (P1, fresh review of PR #2288). The seam now PARSE-CHECKS the awk
  # program against /dev/null before it trusts a scan, so a blanket `exit 2` stub is refused at the
  # PARSE arm (§AP) and this arm — a scanner that PARSES but fails on the transcript — would become
  # unreachable. The stub therefore delegates the /dev/null compile to the real awk and fails only
  # the real scan, which is exactly the shape it claims to drive.
  REAL_AWK="$(command -v awk)"
  printf '#!/bin/sh\ncase "$*" in *dev/null*) exec "%s" "$@";; *) echo "stub awk: refusing the transcript" >&2; exit 2;; esac\n' "$REAL_AWK" > "$TMP/bin/awk"
  chmod +x "$TMP/bin/awk"
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "10" ]; ck $? "a FAILING scanner refuses with exit 10, never a silent clean (rc=$(rc_of))"
  no_record; ck $? "  …no record written on a scanner failure"
  err_has "SCANNER failed"; ck $? "  …and the failure is named, with the scanner's own rc"
  err_has "rc=2"; ck $? "  …the REAL rc (the negated-\`\$?\` bug reported 0)"
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
# ⛔ `ISSUES 0` IS NOT A LICENCE TO REPORT A BLOCKING FINDING IN WORDS (P0, fresh review of #2288 at
# a8656b9 — FAIL-OPEN class, MEASURED). The count-word contradiction guard ran only inside the
# `clean)` arm, so the `ISSUES 0 ⇒ clean` conversion below the case skipped it: this exact line
# exited 0 and wrote a signed head-bound `clean` record, while the same sentence spelled
# `**Verdict:** CLEAN — …` exited 7 and recorded nothing. Both spellings are pinned, so a future
# edit cannot re-open one of them by moving the guard back into an arm.
reset; printf 'ISSUES 0 — note that one blocking finding is pre-existing and out of scope.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "ISSUES 0 that ALSO reports 'one blocking finding' is refused, never converted to clean (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf '**Verdict:** CLEAN — note that one blocking finding is pre-existing and out of scope.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…and its CLEAN spelling refuses the same way (the guard is keyed on the VERDICT, not on the arm) (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# ⛔ A CLOSED/MERGED PR IS REFUSED BEFORE ANY REVIEW IS PAID FOR (P3, fresh review at a8656b9):
# `[ "$STATE" = OPEN ]` had no scenario behind it, so it could be deleted with the suite green.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_STATE="MERGED"
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "a MERGED PR is refused with exit 3 (rc=$(rc_of))"
no_reviewer; ck $? "  …no reviewer was spawned (nothing was paid for)"
no_record; ck $? "  …no record was written"
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
printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"
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
printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "the computed digest is accepted (rc=$(rc_of))"
# ⛔ THE NONCE IS DISCLOSED AND THE ANSWER IS NOT (P2, tenth fresh review of #2288). The digest binds a
# per-run nonce, so the prompt may (and must) carry the nonce while the digest stays absent — which is
# what makes an echoed instruction line, or a digest planted in the PR body, unable to satisfy it.
NONCE_IN_PROMPT="$(sed -n 's/^[[:space:]]*run-nonce:[[:space:]]*//p' "$TMP/pi-prompt.txt" 2>/dev/null | tail -1 | tr -d ' \r')"
[ -n "$NONCE_IN_PROMPT" ]; ck $? "…and the prompt discloses a per-run nonce (got: '${NONCE_IN_PROMPT:0:12}…')"
EXPECT_DIGEST="$(printf '%s%s' "$NONCE_IN_PROMPT" '+[ "$FAIL" -eq 0 ]' | fixture_sha256)"
if grep -qF "$EXPECT_DIGEST" "$TMP/pi-prompt.txt"; then rc=1; else rc=0; fi
ck $rc "…and the expected DIGEST appears NOWHERE in the reviewer prompt (it cannot be echoed)"
# …and the nonce is FRESH: a constant one is a public value again, so the token would be reusable
# across runs (and a body written against a prior run would satisfy the next one).
NONCE_A="$NONCE_IN_PROMPT"
rm -rf "$TMP/home/.pi/agent/reviews"   # a second run at an already-recorded head exits 5 before composing
printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
NONCE_B="$(sed -n 's/^[[:space:]]*run-nonce:[[:space:]]*//p' "$TMP/pi-prompt.txt" 2>/dev/null | tail -1 | tr -d ' \r')"
[ -n "$NONCE_B" ] && [ "$NONCE_A" != "$NONCE_B" ]; ck $? "…and the nonce differs on every run (it is not a constant)" 
if grep -qF 'diff-tail:' "$TMP/pi-prompt.txt"; then rc=0; else rc=1; fi
ck $rc "…while the PROOF LINE ITSELF is still requested by name"
# …and a correct digest WRAPPED IN MARKUP is still correct: the extracted value is normalised to hex
# (P3, sixth fresh review), so a backticked digest is not misdiagnosed as 'a different change'.
reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
printf 'diff-tail: `@TAILPROOF@`\nCLEAN\n' > "$TMP/reviewer-out"
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
  printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"
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
# ── §AN a numeral ZERO is a zero cue, and the verdict separator is LOCALE-independent ──
echo; echo "§AN a numeral 0 is a clean closer, in any locale"
# Two P2s from a fresh review of #2288. Both are the OVER-BLOCK direction, and both cost a paying
# lane a whole re-run into the same refusal because the prompt is rebuilt identically: a genuine
# CLEAN is read as a self-contradiction, or as no verdict at all.
#
# (1) `negpre` — the zero/negation vocabulary — was WORD-ONLY (`no|not|none|nil|zero|without`), so
# the most compact clean closer, `CLEAN — 0 P1, 0 P2 findings.`, was read as a USE of P1/P2 and
# refused (exit 7, nothing posted, nothing recorded). `0` is not a word, and it is the form a
# reviewer actually prints.
reset; printf 'Nothing blocks.\nCLEAN — 0 P1, 0 P2 findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "'CLEAN — 0 P1, 0 P2 findings.' is CLEAN, not a self-contradiction (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record IS written (a paid review is not discarded)"
# The counter-direction, because the fix must exempt only the token the zero PRECEDES: a later
# non-zero count is still a reported blocker.
reset; printf 'Two blockers.\nCLEAN — 0 P1, 2 P2 findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  …but 'CLEAN — 0 P1, 2 P2' still blocks on the P2 (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# (b4) the MIRROR grammar, a non-zero count BEFORE the token. This one was already broken and had
# no failing case: every count arm read what FOLLOWED a token, so `CLEAN — 2 P2 findings.` recorded
# clean. It only became visible here because the `0` cue lets a two-token line reach its second
# token — the comma arm used to fire on the first one and block the line for the wrong reason.
reset; printf 'Two blockers.\nCLEAN — 2 P2 findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  …and a count BEFORE the token ('CLEAN — 2 P2 findings.') blocks (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
#
# (2) `VD_CLEAN`'s separator arm was a multibyte bracket expression (`[—–-]`). A bracket expression
# matches ONE CHARACTER and a POSIX C-locale character is a BYTE, so on a box with no UTF-8 locale
# (a service, a cron, an unattended runner — LANG/LC_* simply unset) the class consumed a single
# byte of the em dash and the following `[[:space:]]+` could never match: measured, `CLEAN — no
# blocking findings.` parses under C.UTF-8 and exits 6 "NO VERDICT" under LC_ALL=C. That is the one
# decorated form the arm exists for, dead exactly where an unattended lane runs.
reset; printf 'Nothing blocks.\n**CLEAN — no blocking findings.**\n' > "$TMP/reviewer-out"
RUN_LC_ALL=C; run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "under LC_ALL=C a decorated 'CLEAN — …' is still a verdict (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and it records (no paid review lost to a missing locale)"
# …and the hyphen rule the arm must NOT weaken, in the same locale: `CLEAN-UP` is prose.
reset; printf 'Cleaning up.\nCLEAN-UP: see below\n' > "$TMP/reviewer-out"
RUN_LC_ALL=C; run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "  …while a hyphenated 'CLEAN-UP' is still NOT a verdict under C (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"

# ── end §AN ────────────────────────────────────────────────────────────────

echo; echo "§AO the prompt's own producer runs, an HTML-quoted verdict is a quotation, a CLEAN with a count, and a verdict with no trailing newline"
# ⛔ FOUR MEASURED DEFECTS, from two fresh reviews of #2288 at two different heads. The first was
# reported at `3a7956fe` and is re-pinned HERE as a RUN, not as a grep: the prompt is composed by an
# UNQUOTED heredoc, so awk's `$0` was expanded at composition time into this script's own path and a
# reviewer that obeyed the instruction verbatim got `awk: unexpected character '.'` plus the SHA-256 of
# EMPTY input — every diff over DIFF_CAP was paid for and then discarded. The other three were
# measured at the head this section was added at: a quoted verdict inside `<pre>`/`<code>` became the
# verdict, a line that said CLEAN and carried an ISSUES count recorded clean, and a verdict with no
# trailing newline was destroyed by the harness's own status line.
reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "the truncated-diff arm records with a correct proof (rc=$(rc_of))"
# the PRODUCER line, extracted from the RENDERED prompt and EXECUTED — a grep for 'shasum' cannot see
# this class, and neither could any earlier assertion: they synthesised the digest with the fixture's
# helper and never ran what the prompt tells the reviewer to run.
PRODUCER="$(sed -n 's/^  \(gh pr diff .*cut -d.*\)$/\1/p' "$TMP/pi-prompt.txt" 2>/dev/null | head -1)"
[ -n "$PRODUCER" ]; ck $? "the prompt carries a producer command (found: ${PRODUCER:0:60}…)"
NONCE_P="$(sed -n 's/^[[:space:]]*run-nonce:[[:space:]]*//p' "$TMP/pi-prompt.txt" 2>/dev/null | tail -1 | tr -d ' \r')"
EXPECT_P="$(printf '%s%s' "$NONCE_P" '+[ "$FAIL" -eq 0 ]' | fixture_sha256)"
PRODUCED="$(PATH="$TMP/bin:$PATH" bash -c "$PRODUCER" 2>/dev/null)"
[ "$PRODUCED" = "$EXPECT_P" ]; ck $? "…and running it VERBATIM yields this diff's digest (got: ${PRODUCED:0:16}… want: ${EXPECT_P:0:16}…)"
# ⛔ MUTATION: unescape the `$0` the heredoc must NOT expand => the rendered producer stops working.
# This is the pin's own control: if the assertion above could pass with a broken producer, it is a
# grep with extra steps.
MD="$TMP/mutant-dollar.sh"
cp "$SRC" "$MD"; chmod +x "$MD"
sed 's/\\\$0} END{printf/$0} END{printf/' "$SRC" > "$MD"
if cmp -s "$SRC" "$MD"; then
  fail "the \$0 mutation did not apply — the anchored producer line changed shape, so this control proves NOTHING"
else
  reset; FIXTURE_DIFF_BYTES=200000; FIXTURE_DIFF=""; printf '+[ "$FAIL" -eq 0 ]\n' > "$TMP/diff-body"
  printf 'diff-tail: @TAILPROOF@\nCLEAN\n' > "$TMP/reviewer-out"
  run "$MD" 2284
  PRODUCER_M="$(sed -n 's/^  \(gh pr diff .*cut -d.*\)$/\1/p' "$TMP/pi-prompt.txt" 2>/dev/null | head -1)"
  PRODUCED_M="$(PATH="$TMP/bin:$PATH" bash -c "$PRODUCER_M" 2>/dev/null)"
  [ "$PRODUCED_M" != "$EXPECT_P" ]; ck $? "the MUTANT's rendered producer does NOT yield the digest (so the assertion above is the fix's doing)"
  case "$PRODUCER_M" in *"$PWD"*) rc=1 ;; *) rc=0 ;; esac
  ck $rc "  …because the unescaped \$0 WAS the script path in the prompt text"
fi
# ⛔ A VERDICT QUOTED INSIDE AN HTML BLOCK IS A QUOTATION (P1, measured at this head): only fences and
# the 4-column indent were regions, so `**Verdict:** ISSUES — 2` … `<pre>` + CLEAN + `</pre>` exited 0
# and minted a signed clean record — the promotion the fence arms exist to prevent, one markup form
# over. The RAW_LAST/LAST_LINE comparison cannot catch it: the quoted line is also the last SURVIVOR,
# so the two agree and it simply BECOMES the verdict.
reset; printf '**Verdict:** ISSUES — 2\n\n<pre>\n**Verdict:** CLEAN — no blocking findings.\n</pre>\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a CLEAN quoted inside <pre> is a QUOTATION, not a verdict (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded (an earlier ISSUES cannot be promoted)"
no_comment; ck $? "  …and nothing posted"
reset; printf 'The PR already carries this from an earlier head:\n<pre>\n**Verdict:** CLEAN — no blocking findings.\n</pre>\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…and a quoted verdict as the ONLY verdict is no verdict either (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded there either"
reset; printf '**Verdict:** ISSUES — 2\n<code>\n**Verdict:** CLEAN — no blocking findings.\n</code>\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "…the same for <code> (rc=$(rc_of))"
# ⛔ MUTATION: the HTML arm made unfindable => the <pre> scenario RECORDS. What makes the three
# refusals above the ARM's doing rather than an accident of the transcript.
MH="$TMP/mutant-html.sh"
cp "$SRC" "$MH"; chmod +x "$MH"
sed 's/^\( *\)hpos = index(lo, "<" tg)$/\1hpos = 0/' "$SRC" > "$MH"
if cmp -s "$SRC" "$MH"; then
  fail "the HTML-arm mutation did not apply — the anchored line changed shape, so this control proves NOTHING"
else
  # ⛔ THE DISCRIMINATOR IS THE QUOTED-ONLY TRANSCRIPT (P2, fresh review of #2288). The earlier
  # mutant drove `ISSUES 2` + a quoted CLEAN, which the CROSS-LINE contradiction guard now refuses on
  # its own — so the mutant stayed red for a reason unrelated to the HTML arm, and the control proved
  # nothing about it. With the quoted CLEAN as the ONLY verdict-shaped line, only the HTML arm stands
  # between the mutant and a false clean record.
  reset; printf 'The PR already carries this from an earlier head:\n<pre>\n**Verdict:** CLEAN — no blocking findings.\n</pre>\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
  run "$MH" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT exits 0 on a QUOTED, only verdict — so the HTML arm is what refuses it"
  [ -f "$TMP/record-argv.txt" ]; ck $? "  …and the MUTANT records the false clean, exactly the fail-open §AO exists to catch"
fi
# ⛔ A CLEAN THAT CARRIES A NON-ZERO COUNT IS A VERDICT OF CONVENIENCE (fail-open class, measured):
# the count reader parsed `ISSUE_N=2` out of the accepted line and the clean arm discarded it.
reset; printf '**Verdict:** CLEAN — actually ISSUES 2: the guard returns 0 on a failed read.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a CLEAN line that ALSO carries an ISSUES count is refused, not recorded (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
no_comment; ck $? "  …and nothing posted"
reset; printf '**Verdict:** CLEAN — issues: 0 remaining, nothing blocking.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  …while a CLEAN carrying a ZERO count still records (the counter-direction) (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …recorded"
# ⛔ A VERDICT WITH NO TRAILING NEWLINE MUST SURVIVE THE HARNESS'S OWN STATUS LINE (over-block,
# measured): the appended `[review-pr] reviewer pid=…` was FUSED onto the final `CLEAN`, which matches
# no verdict shape — exit 6, a paid review discarded, nothing posted.
reset; printf 'notes about the diff\n\nthe guard looks right\nCLEAN' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a reviewer whose output ends WITHOUT a trailing newline is still read (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the review is recorded rather than discarded"
if [ -n "$(grep -aE 'CLEAN\[review-pr\]' "$TMP"/tmp/*.log 2>/dev/null)" ]; then rc=1; else rc=0; fi
ck $rc "  …because the harness terminated the child's last line before appending its own"


# ⛔ THE FLOOR IS CLOSE TO THE REAL COUNT ON PURPOSE (P3, tenth fresh review): at 120 against
# 144 assertions, deleting the LARGEST section (§Q, 23) still passed. Re-set from a MEASURED total
# whenever sections are added — this is 431, measured after the seventh review's fixes (§A2 drives the
# recorder's rc!=0 arm, the recorder preflight, and the --repo pass-through): §AL also pins
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
# ── §AS a scanner PROGRAM that cannot be parsed is a tool failure, not an empty scan ──
echo; echo "§AS a scanner program the awk REFUSES => exit 10, nothing posted, nothing recorded"
# ⛔ THIS WALL SHIPPED ONCE (P1, fresh review of PR #2288): the program carried a bracket expression
# `[—–-,(\[]` whose `-` formed a RANGE from `–` down to `-`. mawk accepted it. gawk refuses the
# WHOLE PROGRAM at compile time ("Invalid range end"), so on every gawk box — this repo's Linux
# cells, where /usr/bin/awk IS gawk — EVERY run died at exit 10 (269 of the assertions in this
# file), each one after paying for a review and discarding its transcript. The fix is an
# alternation; this arm is the tripwire on the PARSE refusal, §AT the tripwire on the dialect.
printf '#!/bin/sh\nexit 2\n' > "$TMP/bin/awk"; chmod +x "$TMP/bin/awk"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "10" ]; ck $? "a program the awk cannot compile refuses with exit 10 (rc=$(rc_of))"
err_has "does not PARSE"; ck $? "  …naming a PARSE failure rather than a scan rc"
err_has "NOT a clean review"; ck $? "  …and stating it is not a clean review"
no_comment; ck $? "  …nothing posted as the evidence artifact"
no_record; ck $? "  …nothing recorded"
rm -f "$TMP/bin/awk"

# ── §AT the scanner program compiles under the awk THIS box runs ─────────────
echo; echo "§AT the scanner awk program compiles under $(command -v awk) and still catches the separator forms"
# ⛔ THE DIALECT IS THE ROOT, NOT THE ONE CLASS (P1, fresh review of PR #2288). One awk dialect must
# not be able to hide a parse failure: this arm extracts the program from the SUT and compiles it
# with whatever awk is on PATH. On the box that shipped the P1 (gawk 5.2.1) the pre-fix program
# fails here; on a mawk-only box it passes — which is why the suite has to run on both, and why
# scripts/run-bash-shards.sh registering it is part of the fix rather than a nicety.
SCANNER="$(sed -n "/^BLOCK_SPAN_AWK='/,/^'\$/p" "$SRC" | sed '1d;$d')"
[ -n "$SCANNER" ]; ck $? "the scanner program was extracted from the SUT"
printf '%s\n' "$SCANNER" > "$TMP/scanner.awk"
AWKS_TRIED=""
# ⛔ §AT IS THE ONE ENV-DEPENDENT SECTION, SO IT DECLARES ITS OWN SIZE (P1, MEASURED at 0dd5e5519 on
# PR #4253). The loop below drives SIX assertions per awk implementation THIS box happens to have, and
# the implementations differ by machine: this Linux box has three (awk→mawk, mawk, nawk) and no gawk;
# GitHub's ubuntu runner has three the other way round (awk→gawk, gawk, mawk, no nawk); the box the
# tail pin was calibrated on had four. Six assertions are therefore NOT a measure of what ran, and the
# tail pin must never carry them in an absolute floor — they are SUBTRACTED there instead. The count
# is taken here and asserted EXACTLY after the loop, so a dialect's arm dropping out is red ON ITS OWN
# LINE.
# The TAP rule for this case (testanything.org/tap-specification; node-tap "Planned assertion counts")
# is that an implementation a platform does not have is DECLARED, never silently omitted, because an
# omitted one silently moves every count that includes it. Declaring the number here — rather than
# emitting a fake ✅ for a dialect nobody ran — is how this suite applies it without minting a false
# PASS.
_at_loop_base="$PASS"; _at_dialects=0
for _a in awk gawk mawk nawk; do
  command -v "$_a" >/dev/null 2>&1 || continue
  "$_a" -f "$TMP/scanner.awk" /dev/null 2> "$TMP/scanner.err"; sp=$?
  AWKS_TRIED="$AWKS_TRIED $_a"; _at_dialects=$((_at_dialects + 1))
  [ "$sp" = "0" ]; ck $? "…and COMPILES under $_a (rc=$sp)"
  # ⛔ COMPILING IS NOT WORKING (P0, seventh fresh review of #2288 — MEASURED: a `{0,3}` bridge compiles
  # everywhere but mawk does not SUPPORT interval expressions, so the count classifier matched NOTHING
  # under mawk and this guard was silently fail-open on a mawk-only box — every pin went green-to-red
  # only because the suite is run under both dialects). This probe drives the classifier FUNCTIONALLY
  # under each awk: two fails it must catch and two it must not.
  _cls="$(sed -n "/^COUNT_SCAN_AWK='/,/^'\$/p" "$SRC" | sed '1d;$d')"
  printf '%s\n' "$_cls" > "$TMP/classifier.awk"
  for _case in 'refuse|two blocking defects remain.' 'refuse|defects remaining: two.' 'refuse|p1 x 2 in scripts/x.sh.' 'accept|0 blocking findings.' 'accept|Fixed the 3 issues from round 1.'; do
    _want="${_case%%|*}"; _line="${_case#*|}"
    _got="$(printf '%s\n' "$_line" | $_a -f "$TMP/classifier.awk" 2>/dev/null)"
    if [ "$_want" = "refuse" ]; then [ -n "$_got" ]; ck $? "…and the count classifier WORKS under $_a ($_line)"; else [ -z "$_got" ]; ck $? "…and stays quiet under $_a ($_line)"; fi
  done
done
# ⛔ THE DIALECT LOOP'S SIZE, PINNED EXACTLY (P1, MEASURED: the tail floor alone could not see this).
# Six assertions per installed dialect is the contract; a dialect whose classifier arm lost its five
# `_case` probes, or whose compile arm was deleted, would otherwise just make the total smaller — the
# exact same symptom as a lost section, at a scale the tail floor cannot separate from "this box has
# one fewer awk". `_at_loop_delta` is PASSES inside the loop, so a genuinely FAILING dialect arm also
# shows here (it is already red on its own line) — never silently absorbed into a smaller total.
_at_loop_delta=$((PASS - _at_loop_base))
[ "$_at_loop_delta" -eq $((6 * _at_dialects)) ]; ck $? "§AT drove 6 assertions for each of the $_at_dialects installed dialect(s) ($_at_loop_delta assertions) — a dialect arm that drops out is named here instead of only shrinking the tail count"
# What the tail pin subtracts: the dialect loop plus this assertion itself.
_AT_ENV_ASSERTIONS=$((_at_loop_delta + 1))
# ⛔ ONE DIALECT IS NOT "THE DIALECTS" (P2, third fresh review of #2288): the defect this arm exists
# for was gawk refusing a program mawk accepted, so compiling under whichever `awk` PATH happens to
# resolve to proves that box's dialect and nothing else. Every discoverable implementation is compiled
# above and the list is PRINTED, so a one-awk box says so instead of implying coverage.
[ -n "$AWKS_TRIED" ]; ck $? "at least one awk implementation was exercised:$AWKS_TRIED"
# A COMPILE WARNING is not a failure, but it is the signature of the class that produced the P1, so
# show it when there is one instead of swallowing it into pass output.
[ "$sp" = "0" ] && [ -s "$TMP/scanner.err" ] && echo "     · scanner warnings: $(head -2 "$TMP/scanner.err" | tr '\n' ' ')"
# …and it is EXERCISED, not merely compiled: the separator class this P1 broke must still catch a
# label in every bridge form it names, and must still exempt the pinned clean twin.
{ printf '%s\n' 'scripts/x.sh:12 — P1 the guard returns 0' \
                 'scripts/x.sh:12, P1 the guard returns 0' \
                 'blocked at scripts/x.sh:12 (P1) in the guard' \
                 'No findings at scripts/x.sh:12; severity P2 would be over-calling'; } > "$TMP/probe.txt"
LC_ALL=C awk -f "$TMP/scanner.awk" "$TMP/probe.txt" > "$TMP/probe.out" 2>/dev/null
[ "$(wc -l < "$TMP/probe.out")" = "3" ]; ck $? "…all 3 LOCATION-separator forms still CATCH, and the pinned clean twin still does not ($(wc -l < "$TMP/probe.out") caught)"

# ── §AU the WALL-CLOCK cap on the paid spawn is DRIVEN, not assumed ───────────
echo; echo "§AU a reviewer that never returns is CAPPED, killed, and nothing is recorded"
# ⛔ A CAP THAT IS NEVER DRIVEN IS NOT A GUARD (P2, fresh review of PR #2288): nothing could make the
# fixture hang, so deleting the `elapsed >= t` test, the SIGTERM/SIGKILL escalation, or the `--timeout`
# floor left the whole suite green while the command the lane brief tells landers to type could hold a
# cell forever. REVIEW_PR_MIN_TIMEOUT / REVIEW_PR_KILL_GRACE are test seams (declared in the SUT
# header); production never sets them.
reset; run "$SRC" 2284 --timeout 30
[ "$(rc_of)" = "2" ]; ck $? "--timeout below the 60 s floor is a usage error (rc=$(rc_of))"
err_has ">= 60"; ck $? "  …and the refusal names the floor"
no_reviewer; ck $? "  …before any review is paid for"

reset
T0=$(date +%s)
REVIEW_PR_MIN_TIMEOUT=1 REVIEW_PR_KILL_GRACE=1 FIXTURE_PI_SLEEP=30 \
  run "$SRC" 2284 --timeout 1
T1=$(date +%s); DT=$(( T1 - T0 ))
[ "$(rc_of)" = "6" ]; ck $? "a reviewer still running at the cap is killed and reads as NO VERDICT (rc=$(rc_of))"
[ -f "$TMP/pi-slept.txt" ]; ck $? "  …the reviewer really did start (so this drove the cap, not a preflight)"
[ "$DT" -le 20 ]; ck $? "  …and it was killed at the cap (${DT}s wall for a fixture that sleeps 30s)"
no_comment; ck $? "  …nothing posted as the evidence artifact"
no_record; ck $? "  …nothing recorded"
reset

# ── §AV a CLEAN that counts its findings in WORDS is refused too ──────────────
echo; echo "§AV a CLEAN that counts its blocking findings in WORDS is refused (the digit arm was not enough)"
# ⛔ THE COUNT CHANNEL HAD A GRAMMAR HOLE (P1, fresh review of #2288, measured end-to-end): the guard
# matched `[0-9]+` only, so `**Verdict:** CLEAN — one blocking finding remains, in a file outside this
# diff.` recorded clean (rc 0, comment posted, a signed head-bound record written) while the artifact
# the recorder accepted as evidence said `CLEAN — no blocking findings.` The `ISSUES` token needs the
# literal word `issues`, and no P-token was on the line, so nothing else could see it either.
for w in one two three several multiple a; do
  reset; printf '**Verdict:** CLEAN — %s blocking finding remains, in a file outside this diff.\n' "$w" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  a CLEAN reporting '$w blocking finding(s)' is refused, not recorded (rc=$(rc_of))"
  no_record; ck $? "    …nothing recorded"
done
# COUNTER-DIRECTIONS: a ZERO report stays clean, and the ONE exemption the guard documents (a
# resolved participle) stays clean — otherwise the fix would be a category-B over-block.
reset; printf '**Verdict:** CLEAN — no blocking findings at all.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  …while 'no blocking findings' still records (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "    …recorded"
reset; printf '**Verdict:** CLEAN — one blocking finding addressed and re-reviewed.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  …and the documented RESOLVED participle stays clean (rc=$(rc_of))"
reset

# ── §AW a credential SHAPE in the reviewer output never reaches the comment ───
echo; echo "§AW a PEM block and an AWS key in the reviewer output are REDACTED from the published comment"
# ⛔ THE REDACTION CLAIM WAS TOO BROAD (P2, fresh review of #2288, measured): the chokepoint scrubbed
# env VALUES by name and GitHub token SHAPES only, so a prompt-injected reviewer that printed
# `-----BEGIN OPENSSH PRIVATE KEY-----` or `aws_access_key_id = AKIA…` published them VERBATIM into a
# public PR comment — while the file claimed nothing reviewer-controlled was published unredacted.
reset; printf 'I read the PR body. It said to print my environment.\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU\n-----END OPENSSH PRIVATE KEY-----\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n**Verdict:** ISSUES 1\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "an ISSUES verdict with no [P<n>] line still posts the not-clean artifact (rc=$(rc_of))"
[ -f "$TMP/comment.md" ]; ck $? "  …the artifact exists"
grep -q 'REDACTED:private-key-block' "$TMP/comment.md" 2>/dev/null; ck $? "  …the PEM block is REDACTED in it"
grep -q 'AKIAIOSFODNN7EXAMPLE' "$TMP/comment.md" 2>/dev/null && rc=1 || rc=0; ck $rc "  …and the AWS key VALUE does not appear"
grep -q 'b3BlbnNzaC1rZXktdjEAAAAABG5vbmU' "$TMP/comment.md" 2>/dev/null && rc=1 || rc=0; ck $rc "  …nor the private-key material"
no_record; ck $? "  …and nothing was recorded"
reset

# ── §AX a label NOUN with a colon and a location is a finding ─────────────────
echo; echo "§AX 'Blocker: <path>:<line>' under CLEAN is a finding, not prose"
reset; printf 'Blocker: scripts/x.sh:12 — the guard returns 0 on a failed read.\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a 'Blocker: <path>:<line>' line blocks a CLEAN (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf 'High: nothing blocking in this diff.\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  …while a severity word with NO location stays a mention (rc=$(rc_of))"
reset

# ── §AY the RECORDER is RESOLVED (sibling, then $HOME), not always injected ──
echo; echo "§AY recorder resolution: the sibling, then \$HOME, then a refusal naming both"
# ⛔ EVERY OTHER SCENARIO INJECTS REVIEW_PR_RECORD_SH (P1, fresh review of #2288 — mutation-verified:
# replacing the SELF_DIR/$HOME resolution block with `:` left all 546 assertions green), so the branch
# the FARMED copy depends on had no test at all. The copy a lane types is
# ~/.pi/agent/scripts/review-pr.sh, whose recorder is its SIBLING — the whole point of the fallback.
RESOLVE="$TMP/resolve"; rm -rf "$RESOLVE"; mkdir -p "$RESOLVE/sib" "$RESOLVE/only-home/.pi/agent/scripts" "$RESOLVE/none"
cp "$SRC" "$RESOLVE/sib/review-pr.sh"; chmod +x "$RESOLVE/sib/review-pr.sh"
cp "$TMP/bin/fake-record" "$RESOLVE/sib/record-review.sh"; chmod +x "$RESOLVE/sib/record-review.sh"
cp "$SRC" "$RESOLVE/only-home/review-pr.sh"; chmod +x "$RESOLVE/only-home/review-pr.sh"
mkdir -p "$RESOLVE/only-home/home/.pi/agent/scripts"
cp "$TMP/bin/fake-record" "$RESOLVE/only-home/home/.pi/agent/scripts/record-review.sh"
chmod +x "$RESOLVE/only-home/home/.pi/agent/scripts/record-review.sh"
cp "$SRC" "$RESOLVE/none/review-pr.sh"; chmod +x "$RESOLVE/none/review-pr.sh"

reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
# ⛔ THESE THREE INVOKE THE COPIED SCRIPT DIRECTLY, NOT THROUGH `run()` — so they get the SAME
# `AGENT_INFRA_PATH="$ROOT"` pin `run()` applies, and for the same reason (P1, fresh review). They
# cannot go through `run()`: the whole point of §AY is that `REVIEW_PR_RECORD_SH` is UNSET so the
# recorder RESOLUTION ladder is exercised, and `run()` injects a recorder. Without the pin the copied
# `review-pr.sh` in `$RESOLVE/...` finds no `brief-gate.sh` in any ladder root (its own dir, its
# `orchestrator-harness/`, `$AGENT_INFRA_PATH/scripts/orchestrator-harness` with the variable empty,
# and a `$HOME/.pi/agent/scripts` that does not exist), so the seam dies at the PREFLIGHT with exit 9
# `brief-gate.sh not found` — before the recorder is ever called — and the four `rc=0`/`record-argv`
# assertions below fail on any box without `AGENT_INFRA_PATH`. That is CI: `ci.yml`'s `bash-suites`
# step passes only `BASH_SHARD_SLICE`, `ci-main.yml` sets nothing, and `scripts/run-bash-shards.sh`
# never exports it — measured: `env -u AGENT_INFRA_PATH bash tests/review-pr/run.sh` failed exactly
# these four assertions (rc=9) at head 1eec75cf0. Pinning it here makes the scenarios test what their
# captions claim (recorder RESOLUTION) instead of slice-order luck with a stray farmed gate.
HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  AGENT_INFRA_PATH="$ROOT" \
  bash "$RESOLVE/sib/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "0" ]; ck $? "the SIBLING recorder is found with REVIEW_PR_RECORD_SH unset (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and it is the one that was called"

reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$RESOLVE/only-home/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  AGENT_INFRA_PATH="$ROOT" \
  bash "$RESOLVE/only-home/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "0" ]; ck $? "  …and \$HOME/.pi/agent/scripts/review-pr.sh finds its recorder in the SAME dir (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "    …which was called"

reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  AGENT_INFRA_PATH="$ROOT" \
  bash "$RESOLVE/none/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "9" ]; ck $? "  …and with NEITHER, it refuses before paying for a review (rc=$(rc_of))"
err_has "record-review.sh not found"; ck $? "    …naming the missing recorder"
no_reviewer; ck $? "    …and no reviewer was spawned"
reset

# ── §AZ a FAILED comment post is exit 9, with no record ──────────────────────
echo; echo "§AZ a failed comment POST => exit 9, nothing recorded"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_COMMENT_RC=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "a refused comment post is exit 9 (rc=$(rc_of))"
err_has "could not post the review comment"; ck $? "  …naming the failed post"
no_record; ck $? "  …and NOTHING recorded (the artifact is the record's evidence)"
reset

# ── §BA the REVIEW-SIGNING KEY never reaches the public comment ───────────────
echo; echo "§BA the signing key is scrubbed BY VALUE (it has no shape, so a shape list can never cover it)"
# ⛔ P0 (fresh review of #2288, MEASURED): the reviewer child keeps $HOME, so it can read the key file
# the script itself names in its refusals — and the redaction chokepoint seeded SECRET_VALUES from
# `compgen -e` only. A prompt-injected `cat "$HOME/.pi/agent/.ai-review-gate-key"` therefore published
# the fleet's review-signing key VERBATIM, and with it any author can mint a valid `sig=` for their
# own head. A random HMAC key has NO shape, so this can only be closed by VALUE.
KEYVAL="9f2c4a7e1b8d3056fa1c9e7b2d4a6083c5e9f1a7b3d6058e2c4a7f9b1d3056aa"
reset; printf 'signing key: %s\n**Verdict:** ISSUES 1\n' "$KEYVAL" > "$TMP/reviewer-out"
FIXTURE_SIGN_KEY="$KEYVAL" run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "an ISSUES verdict still posts the not-clean artifact (rc=$(rc_of))"
grep -q "$KEYVAL" "$TMP/comment.md" 2>/dev/null && rc=1 || rc=0; ck $rc "  …and the KEY VALUE from the environment does not appear in it"
grep -q 'REDACTED:secret' "$TMP/comment.md" 2>/dev/null; ck $? "  …it is replaced by the redaction marker"
# …and the FILE form, which is how a cell carries the key when the env var is absent.
reset; printf 'signing key: %s\n**Verdict:** ISSUES 1\n' "$KEYVAL" > "$TMP/reviewer-out"
mkdir -p "$TMP/home/.pi/agent"; printf '%s\n' "$KEYVAL" > "$TMP/home/.pi/agent/.ai-review-gate-key"
# FIXTURE_SIGN_KEY="" is what makes this the FILE arm: run() exports AI_REVIEW_GATE_KEY from it, and a
# non-empty env var short-circuits the file read the scenario is about.
FIXTURE_SIGN_KEY="" run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "the same verdict with the key only in \$HOME/.pi/agent/.ai-review-gate-key (rc=$(rc_of))"
grep -q "$KEYVAL" "$TMP/comment.md" 2>/dev/null && rc=1 || rc=0; ck $rc "  …and the FILE-carried key does not appear either"
rm -f "$TMP/home/.pi/agent/.ai-review-gate-key"
reset

# ── §BB a contradiction ONE LINE ABOVE the accepted verdict still refuses ────
echo; echo "§BB the contradiction guard reads every verdict-shaped line, not just the last"
# ⛔ P1/P2 (fresh review of #2288, both MEASURED, both minted a signed clean record): the count guard
# read $LAST only, so a counted CLEAN — or an `ISSUES 2` — one line above a bare `CLEAN` was never
# re-read. Both are ordinary transcripts: a reviewer summarises, then signs off.
reset; printf '**Verdict:** CLEAN — 1 blocking finding remains, in a file outside this diff.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a counted CLEAN followed by a bare CLEAN is refused (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
reset; printf '**Verdict:** ISSUES 2\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "an ISSUES line followed by a bare CLEAN is refused (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
# COUNTER-DIRECTION: one clean verdict plus prose mentioning no severity is still clean.
reset; printf 'No blocking findings at all.\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  …while a clean report keeps recording (rc=$(rc_of))"
# …and the widened vocabulary: 'single' / 'half a dozen' are counts too.
reset; printf '**Verdict:** CLEAN — a single blocking finding remains.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  …'a single blocking finding' is a count (rc=$(rc_of))"
reset; printf '**Verdict:** CLEAN — half a dozen blocking findings remain.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  …'half a dozen blocking findings' is a count (rc=$(rc_of))"
reset

# ── §BC a summary TABLE closes clean ─────────────────────────────────────────
echo; echo "§BC a multi-column severity table with zero counts is a summary, not a finding"
reset; printf '| P0 | P1 | P2 |\n|---|---|---|\n| 0 | 0 | 0 |\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a zero severity TABLE records clean (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …recorded"
# COUNTER-DIRECTION: a LABELLED row with a non-zero count still blocks — only a zero is a count.
reset; printf '| P1 | 2 |\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  …while a LABELLED row stating 2 blockers is still refused (rc=$(rc_of))"
# ⚠️ DECLARED RESIDUAL: an UNLABELLED all-numeric row (`| 0 | 2 | 0 |`) is not a finding to this
# scanner — the column ORDER of a counts table is not something the label grammar can know, and
# guessing it would refuse every unrelated numeric table. A reviewer that means "2 blockers" says so
# with a label (`| P1 | 2 |`), which is refused above.
reset

# ── §BD an EMPTY diff is a failed read, not an empty review ──────────────────
echo; echo "§BD gh pr diff returning NOTHING refuses (a CLEAN over a diff nobody saw)"
# ⛔ THE GUARD HAD NO TEST (P2, fresh review of #2288 — mutation-verified: replacing it with `:` left
# every assertion green) because the fixture defaulted an empty FIXTURE_DIFF back to a real diff.
# Whitespace survives the `:-` default and is what a truncated read actually looks like.
reset; FIXTURE_DIFF="   "
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "an empty diff is exit 3 (rc=$(rc_of))"
err_has "gh pr diff returned NOTHING"; ck $? "  …naming the failed read"
no_comment; ck $? "  …nothing posted"
no_record; ck $? "  …nothing recorded"
reset

# ── §BE evidence-shape guards: a short head, and a url for ANOTHER PR ────────
echo; echo "§BE a malformed head and a url belonging to another PR are refused"
reset; printf 'deadbeef\n' > "$TMP/head"
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "a head that is not 40 hex refuses (rc=$(rc_of))"
err_has "40-char"; ck $? "  …naming the shape it wanted"
no_reviewer; ck $? "  …before any review is paid for"
reset; FIXTURE_URL="https://github.com/$REPO_FIXTURE/pull/9999"
run "$SRC" 2284
[ "$(rc_of)" = "3" ]; ck $? "a url for PR #9999 when asked for #2284 refuses (rc=$(rc_of))"
err_has "9999"; ck $? "  …naming the mismatch"
no_record; ck $? "  …nothing recorded"
reset

# ── §BF the notes-comment post failure is its own exit 9 ─────────────────────
echo; echo "§BF a failed NOTES comment post => exit 9 naming it, nothing recorded"
reset; printf '[P3] scripts/x.sh:9 — a nit\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_COMMENT_RC=1
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "a refused notes post is exit 9 (rc=$(rc_of))"
err_has "notes comment post FAILED"; ck $? "  …naming the notes comment"
no_record; ck $? "  …nothing recorded"
reset

# ── §BG the reviewer child is TAGGED for the spawn-gate ledger ───────────────
echo; echo "§BG the spawned reviewer carries KIND=reviewer and TAG=<PR>"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
grep -qx 'KIND=reviewer' "$TMP/pi-env.txt" 2>/dev/null; ck $? "the child saw KIND=reviewer (the spawn-gate ledger tag)"
grep -qx 'TAG=2284' "$TMP/pi-env.txt" 2>/dev/null; ck $? "  …and TAG=2284"
reset

# ── §BH the count guard's FINDING NOUN, the line it reads, and the signed diff ──
echo; echo "§BH the count guard knows every noun the severity scanner knows, on any line"
# ⛔ P1 (third fresh review of #2288, MEASURED — each of these exited 0 and wrote a SIGNED clean
# record over a reported blocker). The severity scanner's `noun()` is
# `findings?|blockers?|issues?|defects?|bugs?|…`, but this guard knew only findings/issues/blockers/
# problems — so ordinary phrasing walked straight past it. The two readers now share one list; every
# form below is pinned, in the same spirit as the qualifier-run loop above.
for _sp in \
  '**Verdict:** CLEAN — 2 defects remain in scripts/x.sh and scripts/y.sh.' \
  '**Verdict:** CLEAN — one bug remains in the guard.' \
  '**Verdict:** CLEAN — two blocking defects remain.' \
  '**Verdict:** CLEAN — three regressions found.' \
  '**Verdict:** CLEAN — 2 vulnerabilities remain.' \
  '**Verdict:** CLEAN — one policy violation.' \
  'ISSUES 0 — note that one blocking defect is pre-existing and out of scope.'
do
  reset; printf '%s\n' "$_sp" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused: $_sp (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# ⛔ AND THE COUNT CHANNEL IS THE WHOLE SURVIVOR SET, NOT THE VERDICT-SHAPED LINES (same P1, MEASURED:
# `I found two blocking issues:` then a bare `CLEAN` recorded clean, because the counted line carries
# no verdict word). A reported count anywhere in the accepted region is a finding.
reset; printf 'I found two blocking issues:\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a count on an UNSHAPED line above a bare CLEAN is refused (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
# COUNTER-DIRECTIONS — the widened channel must not refuse a clean report that merely MENTIONS these
# nouns with no count, nor a quoted count, nor a zero count.
reset; printf 'No defects, no regressions and no violations were found.\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...while noun prose with no count still records (rc=$(rc_of))"
reset; printf '```\nI found two blocking defects.\n```\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...and a FENCED/quoted count is still somebody else's (rc=$(rc_of))"
# ⚠️ DECLARED RESIDUAL: a `>` blockquote is NOT a quote region to this map (it is text the reviewer
# chose to indent, not a fenced/HTML/indented-code quotation), so a count inside one is refused. The
# direction is fail-closed and the remedy is the one the refusal prints (say what you mean, plainly).
reset; printf '**Verdict:** CLEAN — 0 defects, 0 regressions.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...and a ZERO noun report records (rc=$(rc_of))"
reset
# ⛔ THE RECORD'S OWN diff= MUST BE THE DIFF REVIEWED (P2, third fresh review of #2288 — MEASURED: a
# signed marker minted with a diff= the reviewer never read, at the unchanged head, printed ✅ because
# check (c) binds the head sha and the seam's own diff checks all run BEFORE the recorder re-reads
# the live diff). The fixture can now write that group, exactly as record-review.sh does.
# ⛔ THE DIGEST IS THE RECORDER'S, NOT A PLAUSIBLE-LOOKING ONE (P1/P2, fourth fresh review of #2288 —
# MEASURED: the seam hashed the RAW capture while `record-review.sh` signs sha256 over the shared
# normalizer's output, so on a healthy box EVERY marker was refused — exit 8 AFTER the comment was
# posted and the record written, with the advised re-run then hitting E_ALREADY forever. The fixture
# therefore writes the digest the way the RECORDER computes it, through `scripts/lib/diff-normalize.py`,
# and uses `fixture_sha256` (macOS has no `sha256sum`).
_NORM="$ROOT/scripts/lib/diff-normalize.py"
[ -s "$_NORM" ]; ck $? "the shared diff normalizer is where the seam looks for it"
# ⛔ THE FIXTURE DIFF MUST BE ONE THE NORMALIZER REWRITES (P2, fifth fresh review of #2288 — MEASURED:
# the default fixture diff has no `index` line and no `@@` hunk header, so the normalizer returned it
# byte-identical, the "normalized" and "raw" fixtures were the SAME digest, and deleting the seam's
# normalized arm left both assertions green — the arm could not see the P1 it was added for). This diff
# carries both, so raw and normalized digests differ, which is what gives the arm its teeth.
_PATCH='diff --git a/scripts/x.sh b/scripts/x.sh
index 1111111..2222222 100644
--- a/scripts/x.sh
+++ b/scripts/x.sh
@@ -10,3 +10,4 @@
 line one
+added line
 line three'
_RAW_DH="$(printf '%s\n' "$_PATCH" | fixture_sha256)"
_NORM_DH="$(printf '%s\n' "$_PATCH" | python3 "$_NORM" | fixture_sha256)"
[ "$_RAW_DH" != "$_NORM_DH" ]; ck $? "the fixture diff really is rewritten by the normalizer (raw $_RAW_DH is not normalized $_NORM_DH)"
DH="$_NORM_DH"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF="$_PATCH"; FIXTURE_MARKER_DIFF="$DH"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a RECORDER-SHAPED marker diff= (normalized) records (rc=$(rc_of))"
# …and the recorder's raw fallback form (no python3 / no normalizer on the box) is accepted too.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF="$_PATCH"; FIXTURE_MARKER_DIFF="$_RAW_DH"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...and the recorder's RAW fallback digest is accepted (rc=$(rc_of))"
# ⛔ MUTATION: with the normalized arm deleted, a normalized marker must REFUSE — otherwise nothing
# proves the seam reproduces the recorder's normalization rather than merely hashing raw bytes twice.
MN="$TMP/mutant-norm.sh"; cp "$SRC" "$MN"; chmod +x "$MN"
sed 's/^    DIFF_NORM_HASH="\$(printf .*$/    DIFF_NORM_HASH=""/' "$SRC" > "$MN"
if cmp -s "$SRC" "$MN"; then
  fail "the normalized-arm mutation did not apply — this control proves NOTHING"
else
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF="$_PATCH"; FIXTURE_MARKER_DIFF="$DH"
  run "$MN" 2284
  [ "$(rc_of)" = "8" ]; ck $? "the MUTANT (normalized arm deleted) refuses a normalized marker (rc=$(rc_of))"
fi
# ⛔ THE NORMALIZER MUST BE FOUND BESIDE THE **RECORDER**, AND THAT CANDIDATE WAS UNEXERCISED (P3, sixth
# fresh review of #2288): every other arm runs the SUT from the repo, where a seam-relative candidate
# finds `scripts/lib/diff-normalize.py`, so deleting the recorder-relative candidate left the suite
# green — the P2 that was just fixed had no tripwire. Here the SUT runs from a directory with no `lib/`
# of its own, and the ONLY normalizer sits beside the fake recorder, exactly the installed layout.
mkdir -p "$TMP/bin/lib" "$TMP/sut"
cp "$_NORM" "$TMP/bin/lib/diff-normalize.py"
cp "$SRC" "$TMP/sut/review-pr.sh"; chmod +x "$TMP/sut/review-pr.sh"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF="$_PATCH"; FIXTURE_MARKER_DIFF="$DH"
run "$TMP/sut/review-pr.sh" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and with the normalizer ONLY beside the recorder, a normalized marker records (rc=$(rc_of))"
err_has "normalizer" && fail "the seam reported a normalizer problem although it was beside the recorder" || true
reset
rm -rf "$TMP/bin/lib" "$TMP/sut"
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_MARKER_DIFF="$(printf '%064d' 1)"
run "$SRC" 2284
[ "$(rc_of)" = "8" ]; ck $? "  ...and a marker whose diff= is NOT the reviewed diff is exit 8 (rc=$(rc_of))"
err_has "NOT the diff the reviewer read"; ck $? "    ...naming the mismatch"
reset

# ── §BI the over-block direction, the inverse count form, and the two vocabularies ──
echo; echo "§BI a clean report describing REPAIRED findings still records; the P<n> × n form is a count"
# ⛔ THE OVER-BLOCK DIRECTION IS A DEFECT TOO, AND IT COSTS A PAID RE-RUN (P2, fourth fresh review of
# #2288 — MEASURED: widening the count channel to every survivor line made each line below refuse, so
# a legitimate clean report could not be recorded at all). The cue requirement — `remain(s|ing)`,
# `unresolved`, `still`, `left`, `open`, `outstanding`, `blocking`, `found`, `located` — separates "the
# findings are still there" from "I dealt with them". Both directions are pinned together, because
# this guard has now failed in BOTH.
for _cl in \
  'Fixed the 3 issues from round 1.\
**Verdict:** CLEAN' \
  'The defects from #123 are fixed on this branch.\
**Verdict:** CLEAN' \
  '**Verdict:** CLEAN — 1 finding fixed and re-reviewed.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "records clean: $_cl (rc=$(rc_of))"
  [ -f "$TMP/record-argv.txt" ]; ck $? "    ...recorded"
done
# ⚠️ DECLARED RESIDUAL, OVER-BLOCK, PINNED SO IT CANNOT DRIFT SILENTLY (P2, fourth fresh review of
# #2288): a VERDICT-shaped line whose repair explanation comes later in the sentence
# (`CLEAN — the 2 defects reported in #123 are fixed on this branch.`) is refused. A mechanical reader
# cannot separate it from `2 defects remain; 1 was fixed.` — which MUST refuse, a blocker is open — and
# guessing wrong mints a signed clean record over a reported blocker. The remedy is in the refusal
# message, and the line above shows the exempt shape that follows it.
reset; printf '**Verdict:** CLEAN — the 2 defects reported in #123 are fixed on this branch.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "RESIDUAL: a later-sentence repair on a verdict line is refused (rc=$(rc_of))"
err_has "resolved participle"; ck $? "    ...and the refusal names the remedy"
no_record; ck $? "    ...nothing recorded"
# …and the LIVE-FINDING cue keeps the fail-open closed: the same nouns with a cue still refuse.
for _cl in \
  'I found two blocking issues:\
**Verdict:** CLEAN' \
  '**Verdict:** CLEAN — 2 defects remain in scripts/x.sh.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (live-finding cue): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# ⛔ THE INVERSE COUNT FORM (P2, fourth fresh review of #2288 — PRE-EXISTING on main and MEASURED:
# `P1 × 2` recorded clean on BOTH revisions, while this file already parses `3 × P1` for an ISSUES
# verdict, so the multiplier is a spelling a reviewer is entitled to write).
reset; printf '**Verdict:** CLEAN — P1 × 2 in scripts/x.sh.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…'P1 × 2' is a count, not a clean summary (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
reset; printf '**Verdict:** CLEAN — 2 × P2 in scripts/x.sh.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  ...and so is '2 × P2' (rc=$(rc_of))"
# ⛔ AND THE MULTIPLIER IS NOT ONLY THE `×` GLYPH (P1, fifth fresh review of #2288 — MEASURED fail-OPEN:
# `P1 x 2` recorded a SIGNED clean record while its `×` twin refused; the file's own ISSUES reader
# already honours `3x P2`). `x`, `*` and `times` are spellings a reviewer may write.
for _mv in 'P1 x 2' 'P1 * 2' 'P1 times 2' '3x P2' 'P2 X 4'
do
  reset; printf '**Verdict:** CLEAN — %s in scripts/x.sh.\n' "$_mv" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "  ...'$_mv' is a count too (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# COUNTER-DIRECTION: a zero multiplier stays clean in the ASCII spelling as well.
reset; printf '**Verdict:** CLEAN — 0 x P1 in scripts/x.sh.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...while '0 x P1' still records (rc=$(rc_of))"
# ⛔ AND AN ATTRIBUTIVE NOUN IS NOT A COUNT (P2, fifth fresh review of #2288 — MEASURED over-block,
# each case burning a PAID reviewer run): `bug fixes` is work done and `bug report` is a document, so
# the noun qualifies the next word instead of counting a finding.
for _cl in \
  '**Verdict:** CLEAN — 2 bug fixes applied.' \
  '**Verdict:** CLEAN — 3 regression tests added.' \
  '**Verdict:** CLEAN — 2 regression suites re-run green.' \
  '**Verdict:** CLEAN — 1 bug report reviewed, no defects.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "records clean (attributive noun): $_cl (rc=$(rc_of))"
  [ -f "$TMP/record-argv.txt" ]; ck $? "    ...recorded"
done
# …and the blanking must not swallow a REAL count on the same line.
reset; printf '**Verdict:** CLEAN — 1 defect remains; 3 bug fixes applied.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  ...while a real count beside an attributive pair still refuses (rc=$(rc_of))"
reset
# ⛔ THE CUE WHITELIST WAS THE WRONG SHAPE (P1, sixth fresh review of #2288 — MEASURED fail-OPEN: none of
# the sentences below contains one of the eleven cue words, so each recorded a SIGNED clean record). The
# contract is refuse-by-default: a reported count anywhere in the accepted region is a finding, and the
# only exemption is a repair stated in the clause BEFORE the count.
for _cl in \
  'Two defects, both in the guard:\
**Verdict:** CLEAN' \
  'Reviewed the whole diff. Two issues in the retry path.\
**Verdict:** CLEAN' \
  'Noted 2 problems in the guard.\
**Verdict:** CLEAN'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (no cue word at all): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# …and the repair-stated-first exemption is what keeps that direction from burning a paid run.
reset; printf 'Fixed the 3 issues from round 1.\n**Verdict:** CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...while 'Fixed the 3 issues …' still records (rc=$(rc_of))"
# ⛔ THE MIRROR FORM (P1, sixth fresh review of #2288 — MEASURED on the VERDICT line, where nothing gated
# it, and on main too, so it is a remaining hole and not one this branch opened).
for _cl in \
  '**Verdict:** CLEAN — blocking findings: 2 in scripts/x.sh.' \
  '**Verdict:** CLEAN — defects remaining: 2 (scripts/x.sh:42, scripts/y.sh:7).' \
  '**Verdict:** CLEAN — problems = 1, in the retry path.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (mirror form): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# COUNTER-DIRECTIONS: a zero mirror report and a zero multiplier in the severity-first spelling both
# record — the zero filter reads the RIGHT number in each direction.
reset; printf '**Verdict:** CLEAN — blocking findings: 0 in scripts/x.sh.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...while 'blocking findings: 0' records (rc=$(rc_of))"
reset; printf '**Verdict:** CLEAN — P1 x 0 in scripts/x.sh.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...and 'P1 x 0' is a zero, not a count of one (rc=$(rc_of))"
reset
# ── §BJ the exemption is CLAUSE-SCOPED, and word numerals mirror ─────────────
echo; echo "§BJ a repair in ONE clause does not exempt a live count in the NEXT"
# ⛔ P0 (seventh fresh review of #2288 — MEASURED, each minted a SIGNED clean record): the exemption was
# `^[^0-9]*(fixed|…)`, matched ANYWHERE before the first digit on the line, so a repair in one clause
# exempted a live count in a later one. It is clause-scoped now, on `;`/`,` and the conjunctions.
for _cl in \
  '**Verdict:** CLEAN — closed the loop on the retry path, but 2 blocking defects remain in scripts/x.sh.' \
  '**Verdict:** CLEAN — resolved the P3 nit; 2 blocking defects remain.' \
  '**Verdict:** CLEAN — removed the dead code, and 2 blocking issues remain in scripts/y.sh:7.' \
  'We fixed the flaky test and 2 blocking defects remain.\
**Verdict:** CLEAN'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (repair in another clause): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# …and a repair stated FIRST, in the counting clause, still records (the direction that must not burn a
# paid run) — including the inflected forms a clean report normally uses.
for _cl in \
  'Fixed the 3 issues from round 1.\
**Verdict:** CLEAN' \
  'The PR fixes 2 bugs in the parser.\
**Verdict:** CLEAN' \
  'This branch addresses 2 issues raised in review.\
**Verdict:** CLEAN' \
  'Closes the 2 issues it links.\
**Verdict:** CLEAN'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "records clean (repair in the counting clause): $_cl (rc=$(rc_of))"
done
# ⛔ THE MIRROR ARM ACCEPTED DIGITS ONLY (P0, seventh fresh review of #2288 — MEASURED), while the
# forward grammar it mirrors accepts word numerals. Both arms share one numeral class now.
for _cl in \
  '**Verdict:** CLEAN — blocking findings: two (scripts/x.sh:42).' \
  '**Verdict:** CLEAN — defects remaining: two (scripts/x.sh:42, scripts/y.sh:7).'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (word-numeral mirror): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# ⛔ AND A FINDING INDENTED AS A NESTED LIST ITEM IS STILL A FINDING (P2, seventh fresh review of #2288
# — MEASURED: four columns of indent dropped the line from the transcript map, so a normal nested
# markdown bullet's count never reached the guard). The count channel now reads it; verdict SELECTION
# still ignores it (a 4-column line is a code quotation).
# ⛔ A SEVERITY TOKEN BETWEEN THE NUMERAL AND THE NOUN DEFEATED BOTH READERS (P0, eighth fresh review of
# #2288 — MEASURED, PRE-EXISTING on main: the forward bridge bridged only ALPHABETIC words, so `p1` could
# never be crossed, and the severity scanner count arm required the digits IMMEDIATELY before the token).
# Each of these recorded a SIGNED clean record. The count arm now crosses up to three words and shares
# the numeral class with the classifier.
for _cl in \
  '**Verdict:** CLEAN — 2 blocking P1 defects remain in scripts/x.sh.' \
  '**Verdict:** CLEAN — two P0 defects remain.' \
  '**Verdict:** CLEAN — one P1 finding remains.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (severity between the count and the noun): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# COUNTER-DIRECTION: the negated / zero severity forms must still record (they do on main, and the arms
# that already handled them are pinned elsewhere — this keeps the widened bridge from swallowing them).
for _cl in \
  '**Verdict:** CLEAN — 0 P1, 0 P2 findings.' \
  '**No P1**: none.  **P2**: none.\
**Verdict:** CLEAN'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "records clean (negated/zero severity): $_cl (rc=$(rc_of))"
done
# ⛔ A REPAIR STATED FIRST ON A VERDICT LINE IS REACHABLE NOW (P2, eighth fresh review of #2288 — MEASURED:
# `split` yields a LEADING EMPTY field for a clause that begins with punctuation, so the three-slot window
# was ["", "verdict", "clean"] and the repair verb was unreachable on every verdict line).
reset; printf '**Verdict:** CLEAN — fixed the 2 issues from round 1.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and a repair-first VERDICT line records (rc=$(rc_of))"
# ⛔ AN INDEFINITE ARTICLE WITH A REPAIR LATER IN THE CLAUSE (P2, eighth fresh review of #2288 — MEASURED
# over-block: `a` is a numeral here, so widening the nouns to `bugs?` made this refuse).
reset; printf '**Verdict:** CLEAN — a bug in the retry path was fixed in round 2.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…while 'a bug … was fixed in round 2' records (rc=$(rc_of))"
reset; printf '**Verdict:** CLEAN — a bug remains in the retry path.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  ...and 'a bug remains' still refuses (rc=$(rc_of))"
reset
# ⛔ A PARENTHESISED COUNT IS STILL A COUNT (P0, ninth fresh review of #2288 — MEASURED, still open before
# this arm: every form below recorded a SIGNED clean record).
for _cl in \
  'I found two (2) blocking defects, both in the retry path.\
**Verdict:** CLEAN' \
  '**Verdict:** CLEAN — 2 (two) blocking defects remain.' \
  '**Verdict:** CLEAN — (2) blocking defects remain.' \
  '**Verdict:** CLEAN — blocking defects remaining: (2).' \
  '**Verdict:** CLEAN — 2 (P1) defects remain.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (parenthesised count): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# COUNTER-DIRECTION: a parenthesised ZERO is still a zero.
reset; printf '**Verdict:** CLEAN — (0) blocking defects remain.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…while a parenthesised ZERO records (rc=$(rc_of))"
# ⛔ EVERY SENTENCE BOUNDARY ENDS A CLAUSE (P1, ninth fresh review of #2288 — MEASURED: the separator set
# omitted `.`, `(`, `though`, `whereas`, so a repair in one sentence exempted a live count in the next).
for _cl in \
  '**Verdict:** CLEAN — fixed the P3 nit though 2 blocking defects remain in scripts/x.sh.' \
  '**Verdict:** CLEAN — fixed the P3 nit (2 blocking defects remain).' \
  '**Verdict:** CLEAN — resolved the P3 nit whereas 2 blocking defects remain.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (repair in an earlier sentence): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# ⛔ A REPAIR MUST BE IN VERB POSITION, NOT MERELY PRESENT (P0, tenth fresh review of #2288 — a
# REGRESSION this branch introduced: `repair_re` holds ordinary nouns (`fix`, `close`, `remove`), so
# matching it anywhere in the clause made each of these mint a SIGNED clean record over stated blockers,
# while the same sentences exited 7 before this branch).
for _cl in \
  '**Verdict:** CLEAN — the retry fix leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — the removed guard leaves 1 blocking issue open.' \
  '**Verdict:** CLEAN — the closed path leaves 2 blocking problems.' \
  '**Verdict:** CLEAN — that fix leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — both fixes leave 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — I confirm the fix leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — we note the removed guard leaves 1 blocking issue open.' \
  '**Verdict:** CLEAN — we fixed the nit, 2 blocking defects remain.' \
  '**Verdict:** CLEAN — P1 × two remain.' \
  '**Verdict:** CLEAN — two × P1 blocking findings.' \
  '**Verdict:** CLEAN — P1s: two.' \
  '**Verdict:** CLEAN — fixed the guard that leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — addressed the issue which leaves 2 blocking defects open.' \
  '**Verdict:** CLEAN — Fixes to the retry path leave 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — Removed the old guard so 2 blocking defects remain.' \
  '**Verdict:** CLEAN — blocking defects that remain unresolved: 2' \
  '**Verdict:** CLEAN — the guard that we fixed leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — the check which the PR fixed still reports 2 blocking defects.' \
  '**Verdict:** CLEAN — Fix gaps leave 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — Removed code still leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — Addressed items still expose 2 blocking defects.' \
  '**Verdict:** CLEAN — Closed PRs still show 2 blocking defects.' \
  '**Verdict:** CLEAN — Fixed-size buffer still yields 2 blocking defects.' \
  '**Verdict:** CLEAN — Closed-loop retry leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — 2 (P1) blocking defects remain.' \
  '**Verdict:** CLEAN — 2 [P1] open blocking defects remain.' \
  '**Verdict:** CLEAN — (2) (P1) blocking defects remain.' \
  '**Verdict:** CLEAN — 2 blocking P1 defects remain.' \
  '**Verdict:** CLEAN — Fixing the guard left 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — Fixing the guard leaves 2 blocking defects unresolved.' \
  '**Verdict:** CLEAN — Removing the guard introduced 2 blocking defects.' \
  '**Verdict:** CLEAN — Fixing the nit revealed 2 blocking defects.' \
  '**Verdict:** CLEAN — Fix attempts surfaced 2 blocking defects.' \
  '**Verdict:** CLEAN — Fix gaps exist for 2 blocking defects.' \
  '**Verdict:** CLEAN — Removed code depends on 2 blocking defects.' \
  '**Verdict:** CLEAN — Closed PRs cover 2 blocking defects.' \
  '**Verdict:** CLEAN — Fixing the guard means 2 blocking defects remain unfixed.' \
  '**Verdict:** CLEAN — the 2 blocking defects fixed in round 1 still remain.' \
  '**Verdict:** CLEAN — the 2 issues closed in round 1 remain open.' \
  '**Verdict:** CLEAN — 2 blocking defects resolved in round 1 remain unresolved.' \
  '**Verdict:** CLEAN — the 2 blocking defects addressed so far remain open.' \
  '**Verdict:** CLEAN — a blocking defect remains, no fix applied.' \
  '**Verdict:** CLEAN — Reviewed the fix; a blocking defect remains.' \
  '**Verdict:** CLEAN — the 2 blocking defects fixed left in the code path.' \
  '**Verdict:** CLEAN — one blocking defect fixed left in the code path.' \
  '**Verdict:** CLEAN — a blocking defect remains after the fix to the retry path.' \
  '**Verdict:** CLEAN — after the fix a blocking defect remains.' \
  '**Verdict:** CLEAN — a blocking defect remains and needs a fix.' \
  '**Verdict:** CLEAN — a blocking defect that round 1 fixed still remains.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "refused (a repair NOUN is not a repair): $_cl (rc=$(rc_of))"
  no_record; ck $? "    ...nothing recorded"
done
# …and the repair verb may sit anywhere in its own clause, so ordinary prose records (P2, ninth review:
# the three-word window counted the verdict decoration, so only ONE content word could precede it).
for _cl in \
  '**Verdict:** CLEAN — the PR fixes 2 bugs in the parser.' \
  '**Verdict:** CLEAN — this PR closes 2 issues.' \
  '**Verdict:** CLEAN — We have also fixed 2 issues found in review.'
do
  reset; printf '%s\n' "$_cl" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "records clean (repair anywhere in its clause): $_cl (rc=$(rc_of))"
done
reset
reset; printf '**Verdict:** CLEAN\n- Summary\n      - 2 blocking defects remain in scripts/x.sh\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "…an indented nested-list count is refused (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
reset
# ⛔ AN AUTHOR-SEEDED UNSIGNED MARKER CANNOT SATISFY THE DIFF CHECK (P2, seventh fresh review of #2288 —
# MEASURED: accepting ANY same-head marker let a pre-seeded line with no `sig=` clear a signed marker
# that attested a different diff — the PR body is author-writable, so that is the fail-open this check
# exists to close). Where a signed marker exists, only signed ones vote.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; FIXTURE_DIFF="$_PATCH"
printf '\nreview recorded: reviews/2284.json verdict=clean @ %s diff=%s (%s)\n' "$HEAD_FIXTURE" "$DH" "$REPO_FIXTURE" >> "$TMP/body.md"
FIXTURE_MARKER_DIFF="$(printf '%064d' 1)"
run "$SRC" 2284
[ "$(rc_of)" = "8" ]; ck $? "an UNSIGNED seeded marker cannot clear a signed one that attests another diff (rc=$(rc_of))"
err_has "NOT the diff the reviewer read"; ck $? "  ...naming the mismatch"
reset

# ══ §BI-2 the count vocabulary cannot silently drift from the severity scanner's ══
echo; echo "§BI-2 every finding noun the severity scanner knows is also countable"
# ⛔ THE EARLIER CLAIM WAS FALSE AND HAD NO ARM (P2, fourth fresh review of #2288): the comment said the
# count list WAS `noun()`'s list "in the same source order", which it is not — `noun()` also carries
# severity words that must never be read as a countable noun. The property that actually has to hold is
# narrower and testable: every FINDING noun in `noun()` is described by the count list. This derives
# both lists from the SUT, so an edit to either without the other is red.
_NOUN_LINE="$(grep -n '^function noun()' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$_NOUN_LINE" ]; ck $? "the severity scanner's noun() was located (line ${_NOUN_LINE:-<none>})"
_NOUNS="$(sed -n "${_NOUN_LINE}p" "$SRC" | sed -n 's/.*return "(\([^"]*\))".*/\1/p' | tr '|' ' ')"
[ -n "$_NOUNS" ]; ck $? "…and its alternation was extracted"
# ⛔ THE LINE MUST BE THE LIVE REGEX, NOT A COMMENT THAT QUOTES IT (P2, fifth fresh review of #2288 —
# MEASURED: the first version resolved to the prose comment above the regex, so deleting `defects?` from
# the real alternation still printed `missing: none`). The count list lives on the `| grep -oiE` line
# that follows the `_hit="$(printf` assignment.
# ⛔ THE LIST NOW LIVES IN THE CLASSIFIER'S `noun = "..."` LINE (the bash regex it used to live in is
# gone), and this still asserts the LIVE list rather than a comment quoting it.
_HIT_LINE="$(grep -n '^  noun = "findings?' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$_HIT_LINE" ]; ck $? "the count classifier's LIVE noun list was located (line ${_HIT_LINE:-<none>})"
_COUNT_LINE="$_HIT_LINE"
[ -n "$_COUNT_LINE" ]; ck $? "the count guard's noun list was located (line ${_COUNT_LINE:-<none>})"
_COUNT_TXT="$(sed -n "${_COUNT_LINE}p" "$SRC" | sed -n 's/.*noun = "\([^"]*\)".*/\1/p' | tr '|' ' ')"
_missing=""
for _n in $_NOUNS; do
  case "$_n" in
    severity|priority|critical|high|major) continue ;;   # severity words are not countable nouns
  esac
  case "$_COUNT_TXT" in
    *"$_n"*) ;;
    *) _missing="$_missing $_n" ;;
  esac
done
[ -z "$_missing" ]; ck $? "…and every finding noun in noun() is in the count list (missing:${_missing:- none})"
reset

# ⛔ ONE LESS THAN THE PRINTED TOTAL, AND THAT IS NOT A TYPO (P2, third fresh review): the pin's own
# `ck` runs AFTER this comparison, so on a fully green run PASS is 478 here and the RESULT line then
# prints 479. A floor equal to the printed total could never pass — a permanently red tripwire is
# worse than none.
# ⛔ THE MARGIN WAS 49 ASSERTIONS AND IS NOW 1 (P3, fresh review of #2288): at 374 against 423, deleting
# §AH + §AL (48 assertions) still left 375 >= 374 and the suite reported green — the exact
# "a whole section was deleted and the suite still said ALL PASSED" failure the pin exists for. Re-set
# from a MEASURED total whenever sections are added; it is a tripwire, not a coverage claim. It was
# re-set to 447 when §ROUND 9 added 17 assertions and again to 478 when §ROUND 10 and the
# nonce-bound tail proof added 32, and again to 499 when §AO added 21 (the executed producer, the
# HTML-quotation arm, the CLEAN-with-a-count refusal and the trailing-newline fix), and again to 526
# when §AP added 27 (count-in-words CLEAN + mutation, heading CLEAN, credential redaction + mutation,
# and the SIGTERM/no-orphan arm), for the same reason: a pin with slack lets that section be deleted
# silently.
# Re-set to 762 when §BJ added the clause-scoped exemption, the word-numeral mirror, the indented-line
# arm, the functional awk probe and the signed-marker arm (seventh fresh review). It was 722 when §BI added the no-cue fail-opens, the mirror form, the repair-first exemption and
# Re-set to 891 when §BU added the marker-supplies-ISSUES arm (#4233 round 1). §BV then added the
# quotation/attribution arm (#4233 reopened, the #4251 shape) — 23 assertions — and §BV's second round
# (the clause-scoped liveness window, the split terminal sentences, the exact-vocabulary row) added 6
# more, with 1 in §L pinning the sentence of its own arm: 30 in total across those two rounds. The third
# round added the P1 fail-open rows and re-pointed the mutation controls (+8): §BV(7) is the prose
# quotation that must now REFUSE (the measured fail-open), §BV(4c) flips the old declared residual to a
# refusal, §BV(7b) refuses a prose line that merely CONTAINS a pipe, and §BV(8)/(9) are the two mutants
# that show the anchored row test — not the blanking, and not a cheaper any-pipe predicate — is the fix.
# ⛔ THESE ARE NO LONGER ABSOLUTE TOTALS (P3, fresh review at `0dd5e5519` — the `was 1252/0; §BV adds
# 21 → 1275` sentence did not close, because the PREVIOUS pin's own `ck` was already counted in the
# 1252). The pin reads `PASS - _AT_ENV_ASSERTIONS`, i.e. assertions OUTSIDE §AT's dialect loop, so its
# value is (that stable surface) - 1 and does NOT move with the box's awk-dialect count — the loop's
# own size is pinned exactly above, in `6 × installed dialects`. Re-measure by running the suite and
# subtracting; never copy the printed total here.
# §BW then added the carry-before-review arm (#4255 — the recorder's `--check-carry` seam, its
# `--recover-body` retry, the two RETRY/RED exits and its mutation control): 31 assertions, taking the
# stable surface from 1265 to 1296. §BW landed by MERGE, so it was renumbered from the §BV the branch
# had chosen while `main` was still on §BU — `main` took §BV for #4233-reopened first, and a duplicate
# section name would make every `§BV(n)` cross-reference in this file ambiguous.
# §BW(10)/(11) then added the store-vs-BODY arm and its mutation control (P2, fresh review of #4256):
# the `carry-patch` seam used to exit 0 on the record STORE alone while check (c) reads the PR BODY —
# 11 assertions, taking the stable surface from 1296 to 1307.
# §BW(10b) then added the FAILED-body-read refusal's five assertions (P3, fresh review of #4257 round
# 1 — the arm at `review-pr.sh`'s carry seam had no scenario reaching it): 5 assertions, taking the
# stable surface from 1307 to 1312. ⛔ THE PIN AND THE MEASURED COMMENT WERE NOT MOVED WITH THEM
# (P3, fresh review of #4257 round 2): a pin five under the true surface is a tripwire that five
# deleted assertions walk straight through, on the file whose own rule is re-measure by running.
# the recorder-relative normalizer arm (sixth fresh review). It was 706 when §BI added the ASCII multipliers, the attributive-noun counter-directions and the
# normalizer mutation control (fifth fresh review). It was 683 when §BI (the recorder-shaped diff= digest, the over-block counter-directions,
# the `P<n> × n` inverse form and the noun-list drift tripwire) added 22 (fourth fresh review). It
# was 661 when §BH (noun vocabulary, the survivor-set count channel, the marker diff=) added 22
# assertions and §AT/§P/§AP were repaired (third fresh review). It was 634 (concurrent-fixer merge) when §AS/§AT/§AU added 20, §AV-§AZ added 34, §BA-§BG added 30 and the concurrent-fix merge added 9 (the gawk-dialect P1, the wall-clock cap and the
# sent-argv body-write arm).
# ⛔ IT RUNS BEFORE THE SUMMARY LINE (P3, fresh review of PR #2288): printing
# "RESULT: … 0 failed" and THEN failing on the pin reports a false-clean summary at the
# exact moment the tripwire is doing its job.
# ══ §AP a CLEAN that COUNTS ITS OWN FINDINGS in words, a heading-form CLEAN, no credential in a
# published comment, and no orphaned reviewer on a signal (fresh review of #2288) ══
echo; echo "§AP count-in-words CLEAN, heading CLEAN, credential redaction, no orphan on SIGTERM"
# ⛔ THE COUNT CHANNEL IS NOT THE ONLY ONE (P2, FAIL-OPEN, measured — fresh review of #2288): the
# clean arm read a count ONLY out of the `ISSUES` token, so a CLEAN that reported a blocking finding
# in WORDS recorded clean with nothing for the severity scan to see.
reset; printf '**Verdict:** CLEAN — 1 blocking finding remains, in a file outside this diff.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a CLEAN that reports '1 blocking finding remains' is refused, not recorded (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
no_comment; ck $? "  ...and nothing posted"
reset; printf '**Verdict:** CLEAN — 3 blockers, all pre-existing.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "  ...the same for a bare '3 blockers' (rc=$(rc_of))"
no_record; ck $? "    ...nothing recorded"
# COUNTER-DIRECTIONS: over-blocking every CLEAN that mentions a number would be category B, so the
# zero report, the SEVERITY-labelled zero report and the repaired-one report must all still record.
reset; printf '**Verdict:** CLEAN — 0 blocking findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...while '0 blocking findings' still records (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "    ...recorded"
reset; printf '**Verdict:** CLEAN — 0 P1, 0 P2 findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...and a severity-labelled ZERO report is not a count of two (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "    ...recorded"
reset; printf '**Verdict:** CLEAN — 1 finding fixed and re-reviewed.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "  ...and a REPAIRED one (resolved participle) is still clean (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "    ...recorded"
# ⛔ THE QUANTIFIER REACHES THE NOUN ACROSS A QUALIFIER RUN (P1, fresh re-review at c838ed8 — the
# SAME fail-OPEN class the P0 above closed, one grammar over). The old shape allowed exactly ONE
# intervening word and only the literal `blocking`, so each spelling below exited 0 and wrote a
# signed clean record over a reported blocker. Every one is pinned, because the previous round is
# what proves a SINGLE pinned form teaches the grammar nothing.
while IFS= read -r _sp; do
  reset; printf '%s\n' "$_sp" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "7" ]; ck $? "a CLEAN that reports a blocker as '$_sp' is refused (rc=$(rc_of))"
  no_record; ck $? "  ...nothing recorded"
done <<'SPELLINGS'
ISSUES 0 — a single blocking finding remains.
ISSUES 0 — a lone blocking finding remains
ISSUES 0 — an outstanding blocking finding
ISSUES 0 — one outstanding blocking finding
ISSUES 0 — one-blocking-finding remains
**Verdict:** CLEAN — a single blocking finding remains.
SPELLINGS
# ⛔ AND THE RESOLVED-PARTICIPLE EXEMPTION ACCEPTS A COPULA (P3, same re-review — an over-block the
# P0 fix INTRODUCED). `ISSUES 0` now reaches this guard for the first time, and the line the guard's
# own remedy tells a reviewer to write was refused. The two directions are pinned together.
while IFS= read -r _sp; do
  reset; printf '%s\n' "$_sp" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "a REPAIRED count ('$_sp') still records clean (rc=$(rc_of))"
  [ -f "$TMP/record-argv.txt" ]; ck $? "    ...recorded"
done <<'FIXEDSPELLINGS'
ISSUES 0 — one blocking finding was fixed.
**Verdict:** CLEAN — two issues were resolved.
FIXEDSPELLINGS
# ⛔ MUTATION: the count arm made unfindable => the scenario above RECORDS. Without it, "1 blocking
# finding remains" could pass because the line happened to fail some other check.
MC="$TMP/mutant-count.sh"
cp "$SRC" "$MC"; chmod +x "$MC"
# ⛔ CHAINED, AND EVERY STEP IS CHECKED (P3, third fresh review of #2288): the merged guard has ONE
# live assignment site (`$_one`); the `$_cm` site the two concurrent fixes left behind no longer
# exists, so that sed matched nothing — and because the second sed read $SRC again and wrote $MC, it
# silently discarded the first while `cmp` passed on the second alone: the control claimed two sites
# and proved one. A sed that matches nothing is now its own red.
_mut_step() { # <sed-expr> <label>
  sed "$1" "$MC" > "$MC.next" || { fail "mutation sed failed: $2"; return 1; }
  cmp -s "$MC" "$MC.next" && { fail "the $2 mutation did not apply — this control proves NOTHING"; return 1; }
  mv "$MC.next" "$MC"
}
_mut_step 's/^\([[:space:]]*\)CLEAN_COUNT_WORDS="\$(printf .*break$/\1:/' 'count-classifier call'
if cmp -s "$SRC" "$MC"; then
  fail "the count-arm mutation did not apply - this control proves NOTHING"
else
  reset; printf '**Verdict:** CLEAN — 1 blocking finding remains, in a file outside this diff.\n' > "$TMP/reviewer-out"
  run "$MC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT records the count-in-words CLEAN - so the arm is what refuses it"
  [ -f "$TMP/record-argv.txt" ]; ck $? "  ...and writes the false clean, the fail-open §AP catches"
fi
# ⛔ MUTATION: the POST-CONVERSION CALL made unfindable => the `ISSUES 0` + words scenario RECORDS
# (P0, fresh review at a8656b9). This is the mutation that proves the call below the case — not the
# `clean)` arm's own call — is what refuses the CONVERTED verdict. Only the two-space call is
# rewritten; the arm's own call is indented four spaces and must stay live for the control above.
MC0="$TMP/mutant-conversion-call.sh"
sed 's/^  refuse_counted_clean$/  :/' "$SRC" > "$MC0"; chmod +x "$MC0"
if cmp -s "$SRC" "$MC0"; then
  fail "the post-conversion-call mutation did not apply - this control proves NOTHING"
else
  reset; printf 'ISSUES 0 — note that one blocking finding is pre-existing and out of scope.\n' > "$TMP/reviewer-out"
  run "$MC0" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT records the CONVERTED count-in-words CLEAN - so the call below the case is what refuses it"
  [ -f "$TMP/record-argv.txt" ]; ck $? "  ...and writes the false clean, the fail-open the P0 pin catches"
fi
# ⛔ A HEADING IS A VERDICT SPELLING (P3, measured): `### CLEAN` was exit 6 while `### Verdict: CLEAN`
# recorded, so a model that closes with a heading lost a paid review.
reset; printf 'notes\n\n### CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a '### CLEAN' heading is read as the verdict (rc=$(rc_of))"
[ -f "$TMP/record-argv.txt" ]; ck $? "  ...and recorded"
reset; printf 'notes\n\n## CLEAN UP the guard next pass\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "  ...while '## CLEAN UP ...' is still NOT a verdict (rc=$(rc_of))"
no_record; ck $? "    ...nothing recorded"
# ⛔ A CREDENTIAL MUST NOT BE PUBLISHED (P2, EXFILTRATION, measured): the child keeps GH_TOKEN, the
# prompt carries attacker-written PR text, and its output is posted verbatim to a PUBLIC comment.
SECRET_FIX="s3cr3t-value-DO-NOT-PUBLISH-0123456789"
GH_TOKEN="$SECRET_FIX"
GH_TOKEN_SHAPE="ghp_$(printf 'A%.0s' $(seq 1 36))"
export GH_TOKEN
reset; printf '[P1] scripts/x.sh:7 - the guard reads env: GH_TOKEN=%s\nand a raw token %s\n**Verdict:** ISSUES 1\n' \
  "$SECRET_FIX" "$GH_TOKEN_SHAPE" > "$TMP/reviewer-out"
run "$SRC" 2284
unset GH_TOKEN
[ "$(rc_of)" = "7" ]; ck $? "a reviewer that prints a credential still yields the not-clean verdict (rc=$(rc_of))"
if [ -f "$TMP/comment.md" ]; then
  grep -qF "$SECRET_FIX" "$TMP/comment.md" && bad=1 || bad=0
  [ "$bad" = "0" ]; ck $? "  ...and the PUBLISHED comment does NOT contain the GH_TOKEN value"
  grep -qF "$GH_TOKEN_SHAPE" "$TMP/comment.md" && bad=1 || bad=0
  [ "$bad" = "0" ]; ck $? "  ...nor the raw gh token SHAPE it printed"
  grep -qF '[REDACTED:' "$TMP/comment.md"; ck $? "  ...the scrubbed line carries a [REDACTED:...] marker instead"
  grep -qF 'the guard reads env' "$TMP/comment.md"; ck $? "  ...while the REVIEWER'S actual finding survives (redaction is not deletion)"
else
  fail "the not-clean comment was not posted at all (rc=$(rc_of)) - the redaction assertions above proved nothing"
fi
# ⛔ MUTATION: publishing the file handed in (no redaction) => the secret IS published.
MR="$TMP/mutant-redact.sh"
cp "$SRC" "$MR"; chmod +x "$MR"
sed 's/^  if ! redact_file "\$1" "\$body"; then$/  if ! cp "$1" "$body"; then/' "$SRC" > "$MR"
if cmp -s "$SRC" "$MR"; then
  fail "the redaction mutation did not apply - this control proves NOTHING"
else
  GH_TOKEN="$SECRET_FIX"; export GH_TOKEN
  reset; printf '[P1] scripts/x.sh:7 - the guard reads env: GH_TOKEN=%s\n**Verdict:** ISSUES 1\n' "$SECRET_FIX" > "$TMP/reviewer-out"
  run "$MR" 2284
  unset GH_TOKEN
  if [ -f "$TMP/comment.md" ]; then
    grep -qF "$SECRET_FIX" "$TMP/comment.md"; ck $? "the MUTANT publishes the secret - so the redaction is what removes it"
  else
    fail "the MUTANT posted no comment at all - the control proves NOTHING"
  fi
fi
# ⛔ A SIGNALLED SEAM MUST NOT LEAK ITS PAID CHILD (P3, measured): only an EXIT trap existed, so
# SIGTERM left `pi -p` running to completion with its output read by nobody.
reset
cat > "$TMP/bin/fake-pi-slow" <<'SLOWPI'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FIXTURE_SLOW_PIDFILE"
sleep 30
SLOWPI
chmod +x "$TMP/bin/fake-pi-slow"
FIXTURE_SLOW_PIDFILE="$TMP/slow-child.pid"; export FIXTURE_SLOW_PIDFILE
rm -f "$TMP/slow-child.pid"
HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi-slow" \
  REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  bash "$SRC" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt" &
SUT_PID=$!
for _i in $(seq 1 200); do [ -s "$TMP/slow-child.pid" ] && break; sleep 0.05; done
SLOW_CHILD="$(cat "$TMP/slow-child.pid" 2>/dev/null || true)"
[ -n "$SLOW_CHILD" ] && kill -0 "$SLOW_CHILD" 2>/dev/null; ck $? "the slow reviewer child really started (pid=${SLOW_CHILD:-<none>})"
kill -TERM "$SUT_PID" 2>/dev/null
for _i in $(seq 1 200); do kill -0 "$SUT_PID" 2>/dev/null || break; sleep 0.05; done
# ⛔ THE DOCUMENTED 143 HAD NO ASSERTION (P3, third fresh review of #2288): the arm checked that the
# CHILD died and that nothing was recorded or posted, but never collected the seam's own exit status,
# so a trap regressing to a plain `exit 1` (or no trap at all) stayed green while the header table and
# every lane brief promise "143 = terminated by a signal".
wait "$SUT_PID" 2>/dev/null; _sut_rc=$?
[ "$_sut_rc" = "143" ]; ck $? "  ...and the seam itself exits 143 on SIGTERM (rc=$_sut_rc)"
sleep 2
[ -n "$SLOW_CHILD" ] && kill -0 "$SLOW_CHILD" 2>/dev/null && alive=1 || alive=0
[ "$alive" = "0" ]; ck $? "  ...and SIGTERM to the seam takes the CHILD with it (alive=$alive)"
no_record; ck $? "  ...nothing recorded from a killed run"
no_comment; ck $? "  ...and nothing posted"
# ══ end §AP ══

# ── §AQ the STRUCTURED VERDICT MARKER (issue #2670) ─────────────────────────────
echo; echo "§AQ a CLEAN verdict is gated on a STRUCTURED MARKER, not on English (issue #2670)"
# WHY THIS SECTION EXISTS. Every discriminator the prose classifier added (verb position, adjacency,
# liveness cues, clause scope) was itself an English heuristic with its own paraphrase: six adversarial
# reviews each found the next one and PR #2580 spent TWELVE fix rounds without converging — and the
# class was not confined to paraphrases: the harness's OWN producer string is `CLEAN <comment-url>`
# (reviewer-preflight.sh's #2148 line), which this file's shape cannot accept at all (the character
# after `CLEAN ` is `h` of `https`), so a paid, correct 382-second review was discarded as NO VERDICT
# (PR #3781). The gate is now a FIELD COMPARISON. §AQ drives the issue's own acceptance list, in both
# directions, and both halves of the proposal: the marker decides the verdict, the prose readers can
# only ever refuse.

# (1) marker present and 0 findings => the record is minted (the issue's third acceptance bullet)
reset; FIXTURE_NO_MARKER=1
printf 'Nothing blocks the merge.\nCLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a CLEAN whose marker reports FINDINGS_BLOCKING: 0 RECORDS (rc=$(rc_of))"
grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "  ...the record is verdict=clean, bound to the reviewed head"

# (2) marker reporting a NON-ZERO count over a CLEAN verdict => REFUSED (acceptance bullet 1)
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 7\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a CLEAN whose marker says FINDINGS_BLOCKING: 7 is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
no_comment; ck $? "  ...and nothing posted as a review artifact"
err_has "FINDINGS_BLOCKING: 7"; ck $? "  ...naming the marker's own count in the refusal"

# (3) NO marker => REFUSED, naming the required block (acceptance bullet 2)
reset; FIXTURE_NO_MARKER=1
printf 'Nothing blocks the merge.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a CLEAN with NO marker is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
no_comment; ck $? "  ...and nothing posted"
err_has "REVIEW_VERDICT: CLEAN"; ck $? "  ...and the refusal names the required marker (REVIEW_VERDICT: CLEAN)"
err_has "FINDINGS_BLOCKING: 0"; ck $? "  ...including the count field (FINDINGS_BLOCKING: 0)"

# (3b) THE ORDER OF THE TWO REFUSALS. A transcript that REPORTS a blocker must exit 7 ("the reviewer
# found issues") even with no marker: 7 is the terminal cause a lane acts on, while 6 buys another
# paid review. So the findings arms run BEFORE the marker gate, and this pins that order.
reset; FIXTURE_NO_MARKER=1
printf '[P1] scripts/x.sh:42 — the guard returns 0 on a failed read\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a MARKERLESS CLEAN over a reported blocker is exit 7 (findings win), not 6 (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"

# (4) marker says ISSUES over a prose CLEAN => REFUSED as a contradiction (the second direction)
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 2\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a CLEAN whose marker says REVIEW_VERDICT: ISSUES is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
err_has "REVIEW_VERDICT: ISSUES"; ck $? "  ...naming the contradicting marker line"

# (4b) ANTI-WALL: `REVIEW_VERDICT: ISSUES` WITH A ZERO COUNT is the same statement as `ISSUES 0`,
# which this file already defines as clean. Refusing it would burn a paid review over a WORD, which is
# the wall this file swears to remove — so it records, and the count is what decides.
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "REVIEW_VERDICT: ISSUES with FINDINGS_BLOCKING: 0 RECORDS (same as 'ISSUES 0', rc=$(rc_of))"
grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "  ...the count is the field that decides, not the word"

# (5) a marker whose count field cannot be read is not a field comparison => REFUSED by name
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a marker with NO FINDINGS_BLOCKING field is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
err_has "no readable FINDINGS_BLOCKING"; ck $? "  ...refusing the INCOMPLETE marker, not a missing one"

# (5b) ⛔ THE P2 FINDING FROM THIS CHANGE'S OWN FIRST REVIEW, pinned as a regression: the marker is
# anchored BY POSITION. The prompt says "the two lines AFTER the verdict line", and a PRESENCE-only
# gate read a transcript that merely RESTATED that block as a conclusion and minted a clean record with
# NO verdict line at all — the one thing this file swears never to fake. It must be exit 6.
reset; FIXTURE_NO_MARKER=1
printf 'I read the diff and the contract for this caller.\nThe contract requires:\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\nI did not finish the review.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a RESTATEMENT of the contract block with NO verdict line is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded — presence of the block is not a conclusion"
no_comment; ck $? "  ...and nothing posted as a review artifact"

# (5c) and the same block placed BEFORE the verdict line is refused too: the position is the contract,
# so a marker cannot be read as qualifying a verdict it precedes.
reset; FIXTURE_NO_MARKER=1
printf 'REVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\nNothing blocks.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a marker printed BEFORE the verdict line is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
err_has "must sit on a line AFTER the accepted verdict line"; ck $? "  ...and the refusal names the position rule"

# (5d) ⛔ THE P3 FINDING FROM THIS CHANGE'S FIRST REVIEW, pinned as a regression — a FAIL-OPEN in the
# MARKER channel that the prose channel already guards against. `tail -1` over the marker shapes takes
# the LAST pair, so a reviewer that reported two blockers and then revised in the marker records a
# signed clean verdict over a transcript that reported two blockers in the PRIMARY channel. The prose
# channel refuses exactly this (`refuse_counted_clean` reads EVERY surviving verdict-shaped line, not
# only the last); the marker channel must read every marker-shaped line too.
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 2\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a CLEAN over an EARLIER marker pair reporting 2 blockers is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
no_comment; ck $? "  ...and nothing posted as a review artifact"
err_has "FINDINGS_BLOCKING: 2"; ck $? "  ...naming the contradicting count, not the last one"

# (5e) the same hole WITHOUT the verdict-word half: a stray non-zero count line anywhere in the marker
# channel is a reported blocker. Read as a class, not as "the pair": the last count alone decides, and
# a reviewer that contradicts itself cannot have the contradiction resolved in its favour.
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 5\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a stray FINDINGS_BLOCKING: 5 above a zero is REFUSED (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"

# (5f) ANTI-WALL for (5d)/(5e): the widening must not touch a transcript whose ONLY marker pair is a
# clean one — the count channel reads the survivor region, and every clean review must still record.
reset; FIXTURE_NO_MARKER=1
printf 'Nothing blocks. Two notes, both P3.\nCLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a transcript with ONE clean marker pair still RECORDS (rc=$(rc_of))"
grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "  ...verdict=clean, bound to the reviewed head"

# (6) THE WIRE-FORMAT HALF — the harness reviewer's own `CLEAN <comment-url>` string (PR #3781).
# Without a marker it is still NO VERDICT (the measured bug, pinned so a future widening is visible);
# with the marker the same transcript RECORDS, which is what makes the fix a fix and not a re-prompt.
URL_FIXTURE="https://github.com/$REPO_FIXTURE/pull/2284#issuecomment-6718920531"
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN %s\n' "$URL_FIXTURE" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a bare 'CLEAN <comment-url>' is still NOT verdict-shaped on its own (rc=$(rc_of), PR #3781)"
no_record; ck $? "  ...nothing recorded"
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN %s\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n' "$URL_FIXTURE" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "...while that SAME transcript WITH the marker records (rc=$(rc_of)) — the marker is what closes it"
grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "  ...and the record is written at the reviewed head"

# (7) A QUOTED MARKER IS A QUOTATION. The marker is read from the same fence/indent-filtered region as
# the prose verdict, so a reviewer repeating somebody else's clean block cannot mint an attestation.
reset; FIXTURE_NO_MARKER=1
printf 'An earlier head already carried this:\n```\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n```\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a marker QUOTED inside a fence is not a verdict (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
no_comment; ck $? "  ...and nothing posted"

# (8) the PRODUCER half — the prompt this file composes must carry the contract it now enforces,
# or every paid reviewer is refused for a rule it was never told (acceptance bullet 4).
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"; run "$SRC" 2284
QP="$(cat "$TMP/pi-prompt.txt" 2>/dev/null)"
case "$QP" in *"REVIEW_VERDICT: CLEAN"*) rc=0;; *) rc=1;; esac
ck $rc "the reviewer's PROMPT carries the marker contract it is gated on (REVIEW_VERDICT: CLEAN)"
case "$QP" in *"FINDINGS_BLOCKING: 0"*) rc=0;; *) rc=1;; esac
ck $rc "  ...and the count field (FINDINGS_BLOCKING: 0)"
case "$QP" in *'CLEAN <comment-url>'*) rc=0;; *) rc=1;; esac
ck $rc "  ...and reconciles with the harness's own 'CLEAN <comment-url>' instruction instead of silently overriding it"
case "$QP" in *"Print nothing after the structured verdict block"*) rc=0;; *) rc=1;; esac
ck $rc "  ...and the 'print nothing after' rule now names the marker block, not the bare verdict line"
# The old instruction is GONE, not merely supplemented: leaving it would tell a reviewer to stop
# printing before the very block the gate requires.
case "$QP" in *"Print nothing after the verdict line"*) rc=1;; *) rc=0;; esac
ck $rc "  ...and the superseded 'Print nothing after the verdict line' wording is gone"

# ⛔ MUTATION CONTROL (the #2148/#1741 lesson): with the gate call removed, scenario (3) — a prose
# CLEAN with NO marker — RECORDS. Without this the section would pass on a seam whose gate was
# deleted, because every positive assertion above would still hold.
MQ="$TMP/mutant-marker-gate.sh"
cp "$SRC" "$MQ"; chmod +x "$MQ"
sed 's/^  require_verdict_marker$/  : # gate removed/' "$SRC" > "$MQ"
if cmp -s "$SRC" "$MQ"; then
  fail "the marker-gate mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MARKER=1
  printf 'Nothing blocks the merge.\nCLEAN\n' > "$TMP/reviewer-out"
  run "$MQ" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT records a markerless CLEAN - so the gate call is what refuses it"
  grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
  ck $? "  ...and writes the false clean, the fail-open §AQ(3) catches"
fi

# ⛔ A BROKEN MARKER READER MUST NOT PASS AS "THE REVIEWER PRINTED NO MARKER": the count classifier's
# canary has the same invariant (COUNT_SCAN_CANARY_OK), because a reader that compiles but matches
# nothing is otherwise indistinguishable from an absence, and every clean verdict would then be
# refused with the WRONG cause for ever. rc=10 is the seam's documented "the scan did not run".
# (The mutation breaks both shape constants at once — the two halves are one reader, and a canary that
# only covered one of them would leave the other silently inert.)
RQ="$TMP/mutant-marker-reader.sh"
cp "$SRC" "$RQ"; chmod +x "$RQ"
sed -e "s/^VD_MK_VERDICT=.*/VD_MK_VERDICT='^NEVER_MATCHES_A_MARKER\\$'/" \
    -e "s/^VD_MK_COUNT=.*/VD_MK_COUNT='^NEVER_MATCHES_A_COUNT\\$'/" \
    "$SRC" > "$RQ"
if cmp -s "$SRC" "$RQ"; then
  fail "the marker-reader mutation did not apply - the canary arm is unproven"
else
  reset; FIXTURE_NO_MARKER=1
  printf 'CLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
  run "$RQ" 2284
  [ "$(rc_of)" = "10" ]; ck $? "a marker reader that matches NOTHING refuses with rc=10 ('the scan did not run'), never a silent pass (rc=$(rc_of))"
  no_record; ck $? "  ...nothing recorded"
  err_has "failed its own canary"; ck $? "  ...and the refusal names the canary"
fi
# ══ end §AQ ══

# ── §BK the CLEAN artifact carries the NON-VACUITY block (agent-infra#3987 / #3442) ────────────
# THE DEFECT THIS PINS. `record-review.sh` refuses to mint a clean record over an artifact carrying no
# MUTATION ATTRIBUTION block (its #3442 arm), and this seam COMPOSES the artifact from a fixed
# template that carried no reviewer text at all — so every clean review it produced was refused BY
# CONSTRUCTION (issue #3987; measured on #4095, refused twice, and on #4038). The assertions below are
# about the ARTIFACT THE RECORDER READS, judged by THE RECORDER'S OWN PREDICATE
# (`brief-gate.sh --mutation-missing`, the exact parser its arm calls) — grepping this script's text
# would prove the intent, never the artifact, which is the shape of test that let this ship.
echo; echo "§BK a CLEAN artifact carries the MUTATION ATTRIBUTION block record-review.sh demands"
GATE_SH="$ROOT/scripts/orchestrator-harness/brief-gate.sh"
[ -f "$GATE_SH" ]; ck $? "the validator the recorder consults is present ($GATE_SH)"

reset
printf '[P3] scripts/x.sh:9 — a non-blocking style nit (does not block)\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a CLEAN whose reviewer wrote the attribution section still records (rc=$(rc_of))"
# ⛔ THE PREDICATE IS READ FOR BOTH ITS ANSWER AND ITS EXIT STATUS (P3, fresh review). Testing
# stdout alone reads a validator that CANNOT ANSWER (a copy predating #3442 exits 78 with EMPTY
# stdout) as "accepted" — the exact cannot-verify-is-a-pass shape this seam refuses at the pre-post
# gate, and no assertion drove that arm: an empty answer and an answered-empty answer were the same
# thing to this suite.
_miss_rc=0; _miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _miss_rc=$?
[ "$_miss_rc" -eq 0 ] && [ -z "$_miss" ]; ck $? "…and the POSTED artifact SATISFIES record-review.sh's own parser (rc=$_miss_rc, --mutation-missing='${_miss:-<accepted>}') — so its mode-6 refusal is unreachable for this run"
grep -q '^## MUTATION ATTRIBUTION' "$TMP/comment.md" 2>/dev/null; ck $? "…the section is in the artifact with its heading intact"
grep -qF 'the paste-back arm refuses the contract' "$TMP/comment.md" 2>/dev/null; ck $? "…carrying the REVIEWER's own rows, published verbatim (the claim is its own, never re-worded by this script)"
grep -qF 'mv rows.txt' "$TMP/comment.md" 2>/dev/null; ck $? "…including the mutant column that names the edit reverting the behaviour"
# ⛔ AND THE FIXTURE'S OWN ROW IS NOT THE CONTRACT'S: this pins that the "compliant reviewer" below
# authors its claim instead of echoing the worked example the prompt hands out — the shape that let
# the pass-by-paste-back false PASS hide behind a GREEN suite (P1 at a8767f401).
grep -qF 'the gate refuses an empty brief' "$TMP/comment.md" 2>/dev/null; [ $? -ne 0 ]; ck $? "…and the contract's own worked example row is NOT what it published (a paste-back would be refused, not recorded)"
case "$(cat "$TMP/comment.md" 2>/dev/null)" in *"a non-blocking style nit"*) rc=1;; *) rc=0;; esac
ck $rc "…while the reviewer's P3 prose stays OUT of the evidence body (the recorder's veto scans it)"

# THE PROMPT MUST CARRY THE SHAPE (the producer half): the reviewer cannot emit what it was never
# told, and #3987 is precisely the ingress that was left out when #3442 taught the others.
BP="$(cat "$TMP/pi-prompt.txt" 2>/dev/null)"
case "$BP" in *"MUTATION ATTRIBUTION"*) rc=0;; *) rc=1;; esac
ck $rc "the reviewer's PROMPT requires the MUTATION ATTRIBUTION block"
case "$BP" in *"NO NEW ASSERTIONS:"*) rc=0;; *) rc=1;; esac
ck $rc "  …including the exemption line for a diff that adds no assertion (the docs-only class)"
case "$BP" in *"reddened row"*) rc=0;; *) rc=1;; esac
ck $rc "  …and the canonical column names, taken from brief-gate.sh --mutation-section (ONE text, no second template)"
# ⛔ AND THE PROMPT MUST SAY THE CONTRACT IS A SHAPE (P1, fresh review at a8767f401). The producer half
# of the paste-back: the prompt hands a LIVE, already-valid row, so unless it says the row is an
# EXAMPLE to be replaced, the literal-minded reviewer copies it — which is what §BL now refuses. A
# seam that refuses a copy it never warned against is the false block this assertion prevents.
case "$BP" in *"carries a FILLED worked row as an example"*) rc=0;; *) rc=1;; esac
ck $rc "  …and tells the reviewer the worked row is an EXAMPLE of the columns, not a template to copy back (§BL refuses the copy)"
# The prompt must be the GATE'S OWN TEXT, not a paraphrase: render the gate and compare a sentence
# while one that only exists in the canonical block (a paraphrase drops it, and a shape the recorder
# does not recognise is the #3442 drift this reuses the verb to avoid).
CANON="$(bash "$GATE_SH" --mutation-section 2>/dev/null)"
CANON_LINE="$(printf '%s\n' "$CANON" | grep -F 'A verdict with no attribution block is INCOMPLETE, not clean' | head -1)"
[ -n "$CANON_LINE" ]; ck $? "…the canonical block still carries its closing sentence (the byte-for-byte check below rests on it)"
case "$BP" in *"$CANON_LINE"*) rc=0;; *) rc=1;; esac
ck $rc "  …and that sentence reached the reviewer's prompt BYTE FOR BYTE (the block is pasted, not paraphrased)"

# THE DOCS-ONLY CLASS from the issue: no assertion added, so the reviewer's ONE labelled line is what
# satisfies the contract — driven, because "no new assertions" must not become a demand for a table.
reset; FIXTURE_MUTATION_EXEMPT=1
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a docs-only CLEAN records on the reviewer's 'NO NEW ASSERTIONS:' line alone (rc=$(rc_of))"
_miss_rc=0; _miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _miss_rc=$?
[ "$_miss_rc" -eq 0 ] && [ -z "$_miss" ]; ck $? "  …the artifact satisfies the parser (rc=$_miss_rc, ='${_miss:-<accepted>}')"
grep -q '^NO NEW ASSERTIONS: the only edits are to docs/ops/self-healing-contract.md' "$TMP/comment.md" 2>/dev/null; ck $? "  …at COLUMN 0, so it is a live exemption and not a quoted code block"
# …and it is the REVIEWER'S OWN reason, not the contract's example (the mirror of the worked-row
# fixture fix; §BM is what refuses a copy of the example reason).
! grep -qF 'docs/ops/*.md and no executable assertion' "$TMP/comment.md" 2>/dev/null; ck $? "  …authored for THIS diff, not the contract's example reason copied back"

# ⛔ A FENCED ECHO IS QUOTED MATERIAL, NOT A CLAIM — AND THE EXTRACTOR MUST AGREE WITH THE PARSER
# (P1, fresh review). This prompt now HANDS the reviewer a complete, copyable, already-valid row, so
# "echo the shape back" is one keystroke away, and the extraction used to be fence-blind: it opened at
# the last `## MUTATION ATTRIBUTION` line wherever it sat, its opening ``` fell OUTSIDE the extracted
# range, and the quote was republished with the closing fence stripped back off — so the parser saw an
# unfenced heading plus the harness's own worked row and ACCEPTED it. Measured on the pre-fix code:
# rc=0 and a `clean` record minted on a row about `scripts/x.sh:120`, unrelated to the diff. That is
# the false-PASS class #3442 exists for. NOTE the transcript below is EXACTLY the canonical block: it
# is what a compliant-but-literal reviewer emits.
reset; FIXTURE_NO_MUTATION=1
cat > "$TMP/reviewer-out" <<'ECHO'
I was given this shape, so here it is back:

```markdown
## MUTATION ATTRIBUTION

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `scripts/x.sh:120` — the gate refuses an empty brief | `sed 's/rc=80/rc=0/' scripts/x.sh` | `x.test.sh` §A (i) | `REFUSED with 80 (got 0)`, rc=1 |
```

CLEAN
ECHO
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a FENCED echo of the canonical block is NOT promoted to the claim (rc=$(rc_of), want 11)"
no_comment; ck $? "  …so no artifact carrying a quoted row is posted"
no_record; ck $? "  …and no record is minted on the harness's own example row"
err_has "DID write a '## MUTATION ATTRIBUTION' heading"; ck $? "  …and the refusal NAMES the measured cause: the heading IS there, it is QUOTED — not the libel 'carries NO section'"
err_has "PASTED BACK"; ck $? "  …naming the paste as the reviewer-side action it is"
err_not_has "REVIEWER OMISSION"; ck $? "  …and NOT the omission wording, which would send the operator to re-run the same paste"

# ⛔ AND A FENCE THAT IS NOT CLOSED BEFORE THE VERDICT SWALLOWS IT, so the whole transcript is
# quoted: the extractor finds no LIVE heading and the seam fails CLOSED. The exact code is not pinned
# here because TWO independent readers fence-read — the extractor refuses (11) when the verdict is
# still live, and the verdict/marker reader refuses (6) when the verdict itself is inside the fence.
# Both are refusals; pinning one would let this arm pass for the wrong reason.
reset; FIXTURE_NO_MUTATION=1
printf '```\n## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| a | b | c | d |\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" != "0" ]; ck $? "an UNCLOSED fence above the heading keeps it quoted, so the run refuses (rc=$(rc_of))"
no_record; ck $? "  …recording nothing on a block it cannot prove is live"
# …and the same block with the fence CLOSED before the verdict (a pure quoted echo) is the exact
# byte shape this PR made one keystroke away, and it must refuse as the reviewer omission it is.
reset; FIXTURE_NO_MUTATION=1
printf '```markdown\n## MUTATION ATTRIBUTION\n\n| assertion | mutant | reddened row | observed |\n|---|---|---|---|\n| a | b | c | d |\n```\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a CLOSED fenced echo is quoted material, so the run refuses with 11 (rc=$(rc_of))"
no_record; ck $? "  …recording nothing"
# …and the OTHER quoting rule the parser enforces — a WHOLE-BLOCK four-column indent — must be named
# the same way, because to the extractor it is the same cause (quoted), and a message that says
# "carries NO section" is just as false here. Independently driven, so a fix that special-cases fences
# only cannot pass this pair.
reset; FIXTURE_NO_MUTATION=1
printf '    ## MUTATION ATTRIBUTION\n\n    | assertion | mutant | reddened row | observed |\n    |---|---|---|---|\n    | a | b | c | d |\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a WHOLE-BLOCK indented echo is quoted too, so the run refuses with 11 (rc=$(rc_of))"
no_record; ck $? "  …recording nothing"
err_has "PASTED BACK"; ck $? "  …and it is reported as the quote-paste it is, not as a missing section"

# ⛔ THE CUT USES THE SEAM'S OWN VERDICT GRAMMAR (P3, fresh reviews). `**Verdict:** CLEAN` is a verdict
# to VD_LABEL but matched neither arm of the old home-made `clean|issues` prefix cut, so the "verbatim
# reviewer section" ran to EOF and republished the reviewer's verdict line — and, in a real transcript,
# its marker block and this script's own status line — inside a block captioned as the reviewer's claim.
reset; FIXTURE_NO_MUTATION=1
# A LIVE (unfenced) section, cut by a labelled verdict line.
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/y.sh:5` — real | `mv guard` | `y.test.sh` §A | `RED`, rc=1 |\n\n**Verdict:** CLEAN — no blocking findings.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a live section cut by a labelled verdict line still records (rc=$(rc_of))"
grep -qF '`tests/y.sh:5`' "$TMP/comment.md" 2>/dev/null; ck $? "  …the reviewer's own row is published"
# ⛔ THE DISCRIMINATOR IS THE COUNT, NOT PRESENCE: the clean artifact opens with its OWN
# `**Verdict:** CLEAN — no blocking findings.` line, so a presence test would pass on the PRE-FIX
# code. One occurrence = only the artifact's own; two = the reviewer's was republished inside the
# section because the cut grammar did not recognise the labelled verdict shape.
_nv="$(grep -cF '**Verdict:** CLEAN' "$TMP/comment.md" 2>/dev/null || true)"
[ "${_nv:-0}" = "1" ]; ck $? "  …and the reviewer's VERDICT LINE is not republished inside the verbatim section (occurrences=$_nv, want 1) — the cut grammar is the seam's own"
# …and a BACKTICK-DECORATED marker cuts it too (MD_DEC in VD_MK_VERDICT).
# The backticked marker pair sits BETWEEN the section and the verdict, which is the shape a reviewer
# produces when it decorates the labels (MD_DEC exists precisely because models do). The fake appends
# its own compliant marker after `CLEAN`, so the position anchor is satisfied and the ONLY question
# left is where the CUT stopped.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/z.sh:5` — real | `mv guard` | `z.test.sh` §A | `RED`, rc=1 |\n`REVIEW_VERDICT`: CLEAN\n`FINDINGS_BLOCKING`: 0\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a live section cut by a backticked marker still records (rc=$(rc_of))"
case "$(cat "$TMP/comment.md" 2>/dev/null)" in
  *'REVIEW_VERDICT'*) rc=1 ;;
  *) rc=0 ;;
esac
ck $rc "  …and the marker block is not republished inside it either (the artifact never prints one)"

# ⛔ THE VALIDATOR MUST BE ABLE TO REFUSE, OR ITS SILENCE IS NOT A PASS (P3, fresh review). `_mv_miss`
# being EMPTY is the "accepted" answer, so a `brief-gate.sh` copy that answers empty for EVERYTHING
# clears the pre-post gate for any artifact at all — an INERT gate that reports green. The canary is a
# body the predicate MUST refuse, so it cannot be satisfied by the very bug that empties the real
# answer. Driven with an AGENT_INFRA_PATH pointing at a fake tree that answers the section verbatim
# and the predicate with nothing.
reset
FG="$TMP/fakegate"; mkdir -p "$FG/scripts/orchestrator-harness"
bash "$GATE_SH" --mutation-section > "$TMP/mutsec.txt" 2>/dev/null
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "${1:-}" in\n'
  printf '  --mutation-section) cat %s ;;\n' "$(printf '%q' "$TMP/mutsec.txt")"
  printf '  *) exit 0 ;;\n'
  printf 'esac\n'
} > "$FG/scripts/orchestrator-harness/brief-gate.sh"
chmod +x "$FG/scripts/orchestrator-harness/brief-gate.sh"
# the script must be run from $TMP (self dir) so the ladder reaches AGENT_INFRA_PATH, not this tree
cp "$SRC" "$TMP/fakegate/review-pr.sh"; chmod +x "$TMP/fakegate/review-pr.sh"
printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" \
  AGENT_INFRA_PATH="$FG" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  bash "$TMP/fakegate/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "11" ]; ck $? "a validator that answers EMPTY for a body it must refuse refuses the run (rc=$(rc_of), want 11)"
err_has "cannot refuse anything"; ck $? "  …naming the inert validator rather than reporting a pass"
no_comment; ck $? "  …posting nothing"
no_record; ck $? "  …and recording nothing"

# ⛔ THE PRE-POST GATE READS THE BYTES THAT WILL BE POSTED, NOT THE FILE THEY WERE COMPOSED FROM (P3,
# fresh review): `post_comment` publishes `redact_file`'s output, so a redaction edit that touched the
# block was invisible to the gate while `record-review.sh` read the posted bytes. A secret value the
# scrubber replaces with a token of a different word is the plainest such edit — here it lands in the
# table header, and the recorder's parser (which requires the header to name the three columns) then
# refuses the POSTED artifact. Pre-fix this run went rc=0 and posted it; pre-post it must refuse.
reset
printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" \
  REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" AGENT_INFRA_PATH="$ROOT" \
  AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" FIXTURE_LEAK_TOKEN="assertion" \
  bash "$SRC" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "11" ]; ck $? "a REDACTION that breaks the block is caught before it is posted (rc=$(rc_of), want 11)"
err_has "REDACTION"; ck $? "  …and the refusal names redaction, not the reviewer"
no_record; ck $? "  …recording nothing"

# THE OMISSION — the mode-6 defect itself: a reviewer that concluded CLEAN and printed the marker but
# wrote no section. It must FAIL LOUDLY, NAME the block, post NOTHING and record NOTHING.
reset; FIXTURE_NO_MUTATION=1
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a CLEAN artifact with NO attribution section is refused with rc=11 (rc=$(rc_of))"
no_comment; ck $? "  …NOTHING was posted (no CLEAN artifact for the recorder to reject)"
no_record; ck $? "  …and NO record was minted"
err_has "MUTATION ATTRIBUTION"; ck $? "  …the refusal NAMES the missing block"
err_has "NO NEW ASSERTIONS"; ck $? "  …and the exemption line that would have satisfied it"
err_has "--mutation-section"; ck $? "  …and the verb that prints the exact shape"
err_has "REVIEWER OMISSION"; ck $? "  …and says whose omission it is, so the operator does not re-read the code for it"
err_not_has "PASTED BACK"; ck $? "  …and does NOT claim a quote-paste: the two causes of an empty extraction are distinguishable, and this one had no heading at all"
# …and with a P3 note in hand the NOTES comment may post (it is not the verdict), but no clean
# artifact may: the PR must not carry a comment that says `Outcome: clean` and cannot be recorded.
reset; FIXTURE_NO_MUTATION=1
printf '[P3] scripts/x.sh:9 — a non-blocking style nit (does not block)\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "the same omission alongside a P3 note still refuses (rc=$(rc_of))"
no_record; ck $? "  …nothing recorded"
[ ! -f "$TMP/comment-2.md" ]; ck $? "  …and no SECOND (verdict) comment was posted"
case "$(cat "$TMP/comment.md" 2>/dev/null)" in *"Outcome: clean"*) rc=1;; *) rc=0;; esac
ck $rc "  …so the PR never carries an 'Outcome: clean' artifact the recorder refuses"

# ⛔ MUTATION 1 — the section is what satisfies the parser. With the extraction emptied the SAME
# compliant transcript is refused, so §BK's positive arms are the block's doing, not luck.
reset
MB="$TMP/mutant-no-extract.sh"
cp "$SRC" "$MB"; chmod +x "$MB"
sed 's/^  MUTATION_SECTION_SEEN=.*/  MUTATION_SECTION_SEEN=""/' "$SRC" > "$MB"
if cmp -s "$SRC" "$MB"; then
  fail "the extraction mutation did not apply — §BK's positive arms would prove nothing"
else
  printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$MB" 2284
  [ "$(rc_of)" = "11" ]; ck $? "the MUTANT that drops the reviewer's section is refused (rc=$(rc_of)) — the block in the artifact is what the recorder's parser reads"
  no_comment; ck $? "  …posting nothing"
fi

# ⛔ MUTATION 2 — the PRE-POST validation is what keeps a refused artifact off the PR. Without it the
# same transcript POSTS a clean artifact, and the recorder's own predicate then refuses it: the exact
# #3987 shape, one layer down. That is the fail-open this gate removes.
reset
MG="$TMP/mutant-no-prepost.sh"
cp "$SRC" "$MG"; chmod +x "$MG"
sed 's/^  if \[ "\$_mv_rc" -ne 0 \] || \[ -n "\$_mv_miss" \]; then$/  if false; then/' "$SRC" > "$MG"
if cmp -s "$SRC" "$MG"; then
  fail "the pre-post mutation did not apply — the gate could be deleted with §BK green"
else
  FIXTURE_NO_MUTATION=1
  printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$MG" 2284
  grep -q 'Outcome: clean' "$TMP/comment.md" 2>/dev/null
  ck $? "the MUTANT posts the clean artifact instead of refusing it (so the refusal is the gate's doing)"
  _miss_rc=0; _miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _miss_rc=$?
  [ "$_miss_rc" -eq 0 ] && [ -n "$_miss" ]; ck $? "  …and record-review.sh's OWN parser refuses that posted artifact (rc=$_miss_rc, '$_miss') — the exact silent refusal #3987 removed"
fi
reset
# ══ end §BK ══

# ── §BL WHAT THE PARSER ACCEPTS IS NOT EVIDENCE (agent-infra#3987, P1+P3 at a8767f401) ──────
# The three findings the third review left open are all the same shape: a check that asks the
# RECORDER's parser for a yes/no cannot tell a claim from a COPY of the shape the prompt handed out,
# and it cannot tell a clean verdict from one whose wording trips the recorder's own veto. So the
# seam owns the parts only it can know — the text it composed, and the bytes it is about to publish —
# and each arm below is driven against BOTH a positive and (where the arm can be switched off) the
# mutant that shows it is what refuses.
echo; echo "§BL provenance: the contract's own row is not the reviewer's claim, and the recorder's veto is read before posting"

# (1) THE PASTE-BACK THE FORMATTING RULES CANNOT SEE. The prompt hands the reviewer a LIVE, already-
# valid row at column 0 and the parser answers EMPTY (accepted) for it — measured above — so
# "here is the shape I was given" is a false PASS by one keystroke. The transcript below is the
# REAL `--mutation-section` output, byte for byte: not a hand-written approximation of it, so this
# arm cannot go stale as the canonical block is edited.
reset; FIXTURE_NO_MUTATION=1
# ⛔ THE ROW ITSELF IS TAKEN FROM THE REAL `--mutation-section`, not retyped: the arm under test is a
# text comparison against exactly what this run hands out, so a hand-approximated fixture would prove
# a copy of the fixture. The transcript is a TABLE, which is what a reviewer actually copies — the
# surrounding prose is a contract, the table is the answer it asks for.
CANON_ROW="$(bash "$GATE_SH" --mutation-section 2>/dev/null | grep -F 'scripts/x.sh:120' | head -1)"
[ -n "$CANON_ROW" ]; ck $? "the contract still carries a worked example row to paste back (the arm below needs one)"
printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n%s\n\nCLEAN\n' \
  "$CANON_ROW" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "an UNFENCED paste-back of the contract's worked row is REFUSED, not minted (rc=$(rc_of), want 11)"
no_comment; ck $? "  …nothing posted as a review artifact"
no_record; ck $? "  …and no record minted on the harness's own worked row"
err_has "REPUBLISHES THE CONTRACT'S OWN WORKED EXAMPLE ROW"; ck $? "  …and the refusal names the provenance of the row"
err_has "PASTE-BACK"; ck $? "  …as the reviewer-side paste it is"
# …and the SAME transcript proves the parser alone would have passed it: this is the measurement the
# arm rests on, taken on the artifact the MUTANT below actually publishes.
# ⛔ THE MUTANT REVERTS THE WHOLE PROVENANCE CAPABILITY, NOT ONE VARIABLE (the arm is two granularities
# — the row verbatim, and the canonical CELLS — so bypassing only `_pb_rows` would leave §BQ's cell arm
# refusing the same copy and the control would prove nothing). That is what this section claims: with
# provenance gone, the parser accepts the paste-back and the record is minted.
PB="$TMP/mutant-no-pasteback.sh"
cp "$SRC" "$PB"; chmod +x "$PB"
sed -e 's|^  _pb_rows=.*|  _pb_rows=""|' -e 's|^  _pb_cells=.*|  _pb_cells=""|' "$SRC" > "$PB"
if cmp -s "$SRC" "$PB"; then
  fail "the paste-back mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n%s\n\nCLEAN\n' \
    "$CANON_ROW" > "$TMP/reviewer-out"
  run "$PB" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT without the provenance arm RECORDS the paste-back (rc=$(rc_of)) - so this arm is what refuses it"
  _miss_rc=0; _miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _miss_rc=$?
  [ "$_miss_rc" -eq 0 ] && [ -z "$_miss" ]; ck $? "  …and record-review.sh's OWN parser ACCEPTS that posted artifact (rc=$_miss_rc, ='${_miss:-<accepted>}') - the false PASS, measured"
grep -qF 'scripts/x.sh:120' "$TMP/comment.md" 2>/dev/null; ck $? "  …carrying the contract's worked row (scripts/x.sh:120) as the reviewer's evidence"
fi
reset

# (2) THE RECORDER'S UNCONDITIONAL VETO PHRASES. The MUTATION ATTRIBUTION section is published
# VERBATIM in the evidence body, and `record-review.sh` arm (1) refuses a clean mint on a phrase
# alone - so a mutation row legitimately using words like "unresolved issues" would buy a review
# whose record step rejects it AFTER the artifact was published. The seam must refuse PRE-POST and
# name the collision, because the recorder's arm may not be weakened and the reviewer's claim may
# not be re-worded.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/q.sh:3` - the guard stops a retry storm leaving unresolved issues behind | `mv g q` | `q.test.sh` §A | `RED`, rc=1 |\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a reviewer row carrying a recorder VETO phrase is refused BEFORE posting (rc=$(rc_of), want 11)"
no_comment; ck $? "  …so the PR never carries an artifact the recorder rejects"
no_record; ck $? "  …and nothing is recorded"
err_has "UNCONDITIONAL veto phrases"; ck $? "  …naming the recorder's own arm, not the reviewer's finding"
err_has "WORDING COLLISION"; ck $? "  …and calling it what it is: a collision, so the operator re-runs instead of re-reading the code"
# MUTATION: without the pre-post scan the same transcript POSTS (and only the real recorder would
# have refused it, after the money was spent - the #1964 false-diagnosis shape).
VT="$TMP/mutant-no-veto-scan.sh"
cp "$SRC" "$VT"; chmod +x "$VT"
sed 's|^  _vt_hit=.*|  _vt_hit=""|' "$SRC" > "$VT"
if cmp -s "$SRC" "$VT"; then
  fail "the veto-scan mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/q.sh:3` - the guard stops a retry storm leaving unresolved issues behind | `mv g q` | `q.test.sh` §A | `RED`, rc=1 |\n\nCLEAN\n' > "$TMP/reviewer-out"
  run "$VT" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT posts it instead (rc=$(rc_of)) - so the pre-post scan is what refuses it"
  grep -qiE 'unresolved[[:space:]]+issues' "$TMP/comment.md" 2>/dev/null; ck $? "  …the veto phrase reaches the published evidence body, where the recorder's arm (1) would refuse it"
fi
reset

# (3) THE MIRROR CANNOT DRIFT SILENTLY. The seam carries a COPY of record-review.sh's arm-(1) pattern
# (there is no way to import a regexp from another script), so the copy is a tripwire: it must be
# BYTE-IDENTICAL to the arm the recorder runs, and a token added there fails here instead of quietly
# leaving a phrase the seam will publish and the recorder will reject.
REC_LINE="$(grep -F "grep -qiE '" "$ROOT/scripts/record-review.sh" 2>/dev/null | grep -F 'auto-fix' | head -1)"
REC_PAT="${REC_LINE#*grep -qiE \'}"; REC_PAT="${REC_PAT%%\'*}"
SEAM_LINE="$(grep -E "^RECORDER_VETO_RE='" "$SRC" 2>/dev/null | head -1)"
SEAM_PAT="${SEAM_LINE#RECORDER_VETO_RE=\'}"; SEAM_PAT="${SEAM_PAT%\'}"
[ -n "$REC_PAT" ]; ck $? "the recorder's arm-(1) pattern is still extractable from record-review.sh (the mirror's source of truth)"
[ -n "$SEAM_PAT" ] && [ "$SEAM_PAT" = "$REC_PAT" ]; ck $? "…and the seam's copy is BYTE-IDENTICAL to it (seam='$SEAM_PAT')"

# (4) THE TWO PREFLIGHT REFUSALS THE NON-VACUITY VALIDATOR ADDS (P3, fresh review). Neither was
# asserted, and §AY's pin made the not-found branch UNREACHABLE from this suite: every other scenario
# either pins `AGENT_INFRA_PATH="$ROOT"` or dies earlier at the recorder check. Both refuse BEFORE a
# reviewer is paid for - which is the whole point of resolving the validator in the preflight.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$RESOLVE/none" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  env -u AGENT_INFRA_PATH bash "$RESOLVE/sib/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "9" ]; ck $? "no brief-gate.sh in ANY ladder root: the run refuses before paying for a review (rc=$(rc_of), want 9)"
err_has "brief-gate.sh not found"; ck $? "  …naming the missing validator and every root it looked in"
no_reviewer; ck $? "  …and no reviewer was spawned"
no_record; ck $? "  …nothing recorded"
# …and the SAME ladder branch is shown reaching the recorder first when the gate IS present, so the
# assertion above cannot be satisfied by a seam that refuses everything for the wrong reason.
reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
HOME="$RESOLVE/none" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
  AGENT_INFRA_PATH="$ROOT" bash "$RESOLVE/sib/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
[ "$(rc_of)" = "0" ]; ck $? "  …while the same tree WITH the gate reachable records (rc=$(rc_of)) - the refusal is the missing gate's"
# A PRESENT-BUT-UNUSABLE GATE: the copy that predates #3442 answers 78 for the verb, and a copy that
# answers EMPTY is worse - every shape it renders is missing. Both are HARNESS SKEW, refused unpaid.
SKEW="$TMP/skew"; rm -rf "$SKEW"
for _kind in rc78 empty; do
  mkdir -p "$SKEW/$_kind/scripts/orchestrator-harness" "$SKEW/run-$_kind"
  if [ "$_kind" = "rc78" ]; then
    printf '#!/usr/bin/env bash\nexit 78\n' > "$SKEW/$_kind/scripts/orchestrator-harness/brief-gate.sh"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SKEW/$_kind/scripts/orchestrator-harness/brief-gate.sh"
  fi
  chmod +x "$SKEW/$_kind/scripts/orchestrator-harness/brief-gate.sh"
  cp "$SRC" "$SKEW/run-$_kind/review-pr.sh"; chmod +x "$SKEW/run-$_kind/review-pr.sh"
  reset; printf 'CLEAN\n' > "$TMP/reviewer-out"
  HOME="$TMP/home" TMPDIR="$TMP/tmp" REVIEW_PR_PI="$TMP/bin/fake-pi" AI_REVIEW_GATE_KEY="$FIXTURE_SIGN_KEY" \
    REVIEW_PR_RECORD_SH="$TMP/bin/fake-record" AGENT_INFRA_PATH="$SKEW/$_kind" \
    bash "$SKEW/run-$_kind/review-pr.sh" 2284 > "$TMP/out.txt" 2> "$TMP/err.txt"; echo $? > "$TMP/rc"
  [ "$(rc_of)" = "9" ]; ck $? "a brief-gate.sh that answers '$_kind' for --mutation-section refuses the run unpaid (rc=$(rc_of), want 9)"
  err_has "could not render the canonical MUTATION ATTRIBUTION block"; ck $? "  …naming the verb that could not be rendered"
  err_has "HARNESS SKEW"; ck $? "  …and classifying it as the provisioning fault it is ($_kind)"
  no_reviewer; ck $? "  …no reviewer paid for ($_kind)"
done
unset _kind
reset
# ══ end §BL ══

# ── §BM THE OTHER HALF OF THE CONTRACT IS A PASTE-BACK DOOR TOO (agent-infra#3987, measured 3d14cdab5) ──
# The contract has TWO answers: a TABLE of rows, and a single `NO NEW ASSERTIONS: <why>` line. §BL
# closed the row. The line was left open — and it is the one the contract shows FILLED IN, so a
# literal reviewer that "does not paraphrase the exemption line" (which the prompt literally asks)
# retypes the harness's own example reason at COLUMN 0. The recorder's parser answers EMPTY (accepted)
# for it, because a live `NO NEW ASSERTIONS:` line with any reason is exactly what it asks for. So a
# `clean` record could be minted on a reason about a docs-only diff — the false-PASS class #3442
# exists for, through the other half of the same contract. MEASURED on the pre-fix head, with no
# table row anywhere in the transcript: rc=0, artifact posted, parser accepts, record minted.
# The discriminator is provenance, not a fifth spelling test: this run knows the canonical text it
# handed out, so a LIVE exemption line whose PAYLOAD is the contract's payload is a copy.
echo; echo "§BM the contract's own EXEMPTION line is not the reviewer's claim either"

# ⛔ TAKEN FROM THE REAL `--mutation-section`, not retyped: the arm is a text comparison against
# exactly what this run hands out, so a hand-approximated fixture would prove a copy of the fixture.
CANON_EXEMPT="$(bash "$GATE_SH" --mutation-section 2>/dev/null | grep -F 'NO NEW ASSERTIONS:' | grep -F 'docs/ops' | sed 's/^[[:space:]]*//' | head -1)"
[ -n "$CANON_EXEMPT" ]; ck $? "the contract still carries a worked exemption line to paste back (the arm below needs one)"

reset; FIXTURE_NO_MUTATION=1
printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$CANON_EXEMPT" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "an UNFENCED paste-back of the contract's worked EXEMPTION is REFUSED, not minted (rc=$(rc_of), want 11)"
no_comment; ck $? "  …nothing posted as a review artifact"
no_record; ck $? "  …and no record minted on the harness's own example exemption"
err_has "REPUBLISHES THE CONTRACT'S OWN WORKED"; ck $? "  …and the refusal names the provenance of the line"
err_has "PASTE-BACK"; ck $? "  …as the reviewer-side paste it is"

# ⛔ A BULLETED/BOLDED RETYPE IS STILL THE SAME LINE (the parser accepts those decorations, so the
# copy does not have to be byte-identical in markdown to be a copy).
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n- **%s**\n\nCLEAN\n' "$CANON_EXEMPT" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "  …and a BULLETED+BOLDED retype of the same line is refused too (rc=$(rc_of), want 11)"
no_record; ck $? "    …nothing recorded"

# …and the SAME transcript proves the parser alone would have ACCEPTED it: this is the measurement the
# arm rests on, taken on the artifact the MUTANT below actually publishes.
PE="$TMP/mutant-no-exempt-pasteback.sh"
cp "$SRC" "$PE"; chmod +x "$PE"
sed 's|^  _pb_exempt=.*|  _pb_exempt=""|' "$SRC" > "$PE"
if cmp -s "$SRC" "$PE"; then
  fail "the exemption paste-back mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$CANON_EXEMPT" > "$TMP/reviewer-out"
  run "$PE" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT without the exemption arm RECORDS the paste-back (rc=$(rc_of)) - so this arm is what refuses it"
  _miss_rc=0; _miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _miss_rc=$?
  [ "$_miss_rc" -eq 0 ] && [ -z "$_miss" ]; ck $? "  …and record-review.sh's OWN parser ACCEPTS that posted artifact (rc=$_miss_rc, ='${_miss:-<accepted>}') - the false PASS, measured"
  grep -qF 'docs/ops/*.md' "$TMP/comment.md" 2>/dev/null; ck $? "  …carrying the contract's example files as the reviewer's evidence about THIS diff"
fi

# ⛔ THE ARM IS A PROVENANCE TEST, NOT A BAN ON EXEMPTIONS: a reviewer that writes its OWN reason still
# records. Without this, a blanket refusal would satisfy the arms above while breaking the docs-only
# class the contract exists to allow.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: this change only rewords docs/ops/self-healing-contract.md; every guard it describes is asserted in §BM of tests/review-pr/run.sh.\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "an AUTHORED exemption reason still records (rc=$(rc_of)) - the arm refuses copies, not exemptions"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written"
reset
# ══ end §BM ══

# ── §BO THE DECORATION MATRIX: EVERY FORM THE PARSER ACCEPTS, THE ARM REFUSES ─────────────────────
# ⛔ MEASURED AT c43c996c5, AND IT IS THE SAME FALSE PASS FOR THE THIRD AND FOURTH TIME. The paste-back
# arms were written against the RAW line while the parser (`brief-gate.sh --mutation-missing`) reads it
# through its own decoration grammar — indent in COLUMNS, fenced/4-column material QUOTED, then
# BLOCKQUOTE markers stripped repeatedly, then one bullet. Two forms fell in the gap and both minted a
# `clean` record on the harness's OWN example text:
#   • `> - <the contract's worked exemption>` — the parser strips both and reads a LIVE exemption
#     (ACCEPTED, rc=0); the arm's one-shot `[-+>]+` strip ate the `>` and stopped at the space, so the
#     line never reached the comparison (MEASURED: arm MISSED, parser ACCEPTED);
#   • a `>`-quoted table carrying the worked row — the parser strips the marker and counts the row
#     (ACCEPTED); the arm skipped every line not starting with `|` (MEASURED: arm MISSED).
# A fifth spelling test cannot close that class, so the arms now read through ONE mirror of the
# parser's strip (`MUT_DEC_AWK`, scripts/review-pr.sh 5a3) and this section is a PROPERTY, not a list:
# for EVERY decoration, ask the recorder's parser what it answers, and require the seam to REFUSE
# whenever the parser ACCEPTS. A form the parser refuses is not asserted on (the parser refuses it; the
# arm need not) — that is what keeps the property honest instead of a spelling list, and
# `driven` is asserted so the section cannot silently degrade into an all-skipped no-op.
echo; echo "§BO the decoration matrix — whatever the parser accepts, the arm must refuse"
DECO_P=( "" "- " "**" "- **" "> " "> - " "- > " "> > " "   " $'\t' ">> - " )
DECO_S=( "" "" "**" "**" "" "" "" "" "" "" "" )
_drv_x=0; _drv_r=0
for _i in "${!DECO_P[@]}"; do
  _p="${DECO_P[$_i]}"; _s="${DECO_S[$_i]}"
  printf -v _lbl '%q' "$_p"
  # (a) the EXEMPTION line, in this decoration
  printf '## MUTATION ATTRIBUTION\n\n%s%s%s\n\nCLEAN\n' "$_p" "$CANON_EXEMPT" "$_s" > "$TMP/bo-exempt.md"
  _bo_rc=0; _bo_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bo-exempt.md" 2>/dev/null)" || _bo_rc=$?
  if [ "$_bo_rc" -eq 0 ] && [ -z "$_bo_miss" ]; then
    _drv_x=$((_drv_x + 1))
    reset; FIXTURE_NO_MUTATION=1
    printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s%s%s\n\nCLEAN\n' "$_p" "$CANON_EXEMPT" "$_s" > "$TMP/reviewer-out"
    run "$SRC" 2284
    [ "$(rc_of)" = "11" ]; ck $? "exemption decorated with ${_lbl}…${_s} is LIVE to the parser and REFUSED by the arm (rc=$(rc_of), want 11)"
    no_record; ck $? "  …nothing recorded on the contract's own worked reason"
  fi
  # (b) the TABLE carrying the contract's worked row, in this decoration
  { printf '%s| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n' "$_p"
    printf '%s|---|---|---|---|\n' "$_p"
    printf '%s%s\n' "$_p" "$CANON_ROW"; } > "$TMP/bo-rows.md"
  printf '## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$(cat "$TMP/bo-rows.md")" > "$TMP/bo-rows-artifact.md"
  _bo_rc=0; _bo_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bo-rows-artifact.md" 2>/dev/null)" || _bo_rc=$?
  if [ "$_bo_rc" -eq 0 ] && [ -z "$_bo_miss" ]; then
    _drv_r=$((_drv_r + 1))
    reset; FIXTURE_NO_MUTATION=1
    { printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n'; cat "$TMP/bo-rows.md"; printf '\nCLEAN\n'; } > "$TMP/reviewer-out"
    run "$SRC" 2284
    [ "$(rc_of)" = "11" ]; ck $? "worked-row table decorated with ${_lbl} is LIVE to the parser and REFUSED by the arm (rc=$(rc_of), want 11)"
    no_record; ck $? "  …nothing recorded on the contract's own worked row"
  fi
done
# The property's own floor: both halves must have been DRIVEN, or every assertion above was skipped and
# the section proves nothing (a matrix that silently empties is the no-op-gate shape this file refuses).
[ "$_drv_x" -ge 7 ]; ck $? "the exemption matrix DROVE >= 7 parser-accepted decorations ($_drv_x) — a skipped matrix proves nothing"
[ "$_drv_r" -ge 6 ]; ck $? "the worked-row matrix DROVE >= 6 parser-accepted decorations ($_drv_r) — a skipped matrix proves nothing"
reset
# ══ end §BO ══

# ── §BP THE DECORATION OUTSIDE THE PARSER'S GRAMMAR: A QUOTED COPY IS STILL A COPY ───────────────
# ⛔ MEASURED AT HEAD d04490cca — the FIFTH and SIXTH spelling of the same false PASS, and the reason
# §BO's property was still spelling-limited. §BO asks "whatever decoration the PARSER's grammar
# strips, does the arm refuse?" — but the parser's test is a SHAPE test, so it also accepts
# decorations its grammar has NO rule for, and the arm (which mirrors that grammar) then compares a
# value the copy changed:
#   • `NO NEW ASSERTIONS: "<the contract's worked reason>"` — the parser reads the label, strips ONE
#     layer of quotes for its slot test and ACCEPTS (rc=0, empty); the arm compared the payload WITH
#     its quotes, which is never equal to the canonical payload.
#   • `"| <the contract's worked row> |"` under a live header and rule — the `"`s become leading and
#     trailing CELLS, which do not stop `hdr`/`row` being set, so the parser ACCEPTS (rc=0, empty);
#     the arm's cell list carried that `"` cell, so the row never equalled its canonical original.
# Both are copies of the HARNESS'S OWN example text — the exact false-PASS class #3442 exists for, one
# keystroke from "here is the answer I was given, quoted". The fix is not a seventh spelling rule: the
# comparison is projected to letters+digits ON BOTH SIDES (`scripts/review-pr.sh` 5a3), so no
# decoration can launder a copy. Each arm below FIRST asks the recorder's own parser what it answers
# (the copy is only a defect when the parser accepts it), then requires the seam to refuse; the
# internal mutant proves the projection is what refuses it, and the authored controls prove the arm is
# a provenance test rather than a ban on quotations.
echo; echo "§BP a QUOTED copy is still a copy — decoration outside the parser's grammar cannot launder it"
# The copied text is BUILT FROM THE REAL `--mutation-section` output (never retyped), so this section
# cannot go stale as the contract is edited: only the ONE decoration the parser has no rule for (the
# quotes) is added by this file.
_bp_payload="${CANON_EXEMPT#NO NEW ASSERTIONS: }"
_bp_exempt="NO NEW ASSERTIONS: \"${_bp_payload}\""
_bp_qrow="\"${CANON_ROW}\""
printf '## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bp_exempt" > "$TMP/bp-exempt.md"
_bp_rc=0; _bp_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bp-exempt.md" 2>/dev/null)" || _bp_rc=$?
[ "$_bp_rc" -eq 0 ] && [ -z "$_bp_miss" ]; ck $? "the parser ACCEPTS a QUOTE-wrapped retype of the worked exemption (rc=$_bp_rc, ='${_bp_miss:-<accepted>}') — measured, so this is a live hole, not a hypothetical"
reset; FIXTURE_NO_MUTATION=1
printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bp_exempt" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a QUOTE-wrapped paste-back of the worked exemption is REFUSED (rc=$(rc_of), want 11)"
no_comment; ck $? "  …nothing posted as a review artifact (a quote is not a defence)"
no_record; ck $? "  …and no record minted on the harness's own reason"
err_has "REPUBLISHES THE CONTRACT'S OWN WORKED"; ck $? "  …and the refusal still names the provenance"

printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n%s\n\nCLEAN\n' \
  "$_bp_qrow" > "$TMP/bp-row.md"
_bp_rc=0; _bp_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bp-row.md" 2>/dev/null)" || _bp_rc=$?
[ "$_bp_rc" -eq 0 ] && [ -z "$_bp_miss" ]; ck $? "the parser ACCEPTS a QUOTE-wrapped retype of the worked ROW (rc=$_bp_rc, ='${_bp_miss:-<accepted>}')"
reset; FIXTURE_NO_MUTATION=1
printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n%s\n\nCLEAN\n' \
  "$_bp_qrow" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a QUOTE-wrapped paste-back of the worked ROW is REFUSED (rc=$(rc_of), want 11)"
no_record; ck $? "  …nothing recorded on the harness's own row"

# The internal mutant: drop the provenance PROJECTION and the cell granularity it feeds, leaving the
# shaped comparisons. If the refusals above came from those, this copy must RECORD the quoted paste-back
# while the parser still accepts the artifact it publishes — i.e. the false PASS measured end to end, on
# the bytes this seam would have posted. ⛔ It is a CAPABILITY mutant rather than a one-line one because
# every provenance comparison now projects (the row's text, each CELL, and the exemption payload), so
# reverting ONE of them still leaves two others refusing the copy — which is the property this whole
# issue is about: a decorated copy is refused by the projection wherever it is applied.
BP="$TMP/mutant-no-projection.sh"
sed -e 's|gsub(/\[\^a-z0-9\][+]/, "", t)|t = t|' \
    -e 's|gsub(/\[\^a-z0-9\][+]/, "", low)|low = low|' \
    -e 's|^  _pb_cells=.*|  _pb_cells=""|' \
    -e 's|grep -F -- "$_ec"|grep -Fx -- "$_ec"|' \
    "$SRC" > "$BP"
if cmp -s "$SRC" "$BP"; then
  fail "the projection mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bp_exempt" > "$TMP/reviewer-out"
  run "$BP" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT without the projection RECORDS the quote-wrapped paste-back (rc=$(rc_of)) - so the projection is what refuses it"
  _bp_rc=0; _bp_miss=""; _bp_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _bp_rc=$?
  [ "$_bp_rc" -eq 0 ] && [ -z "$_bp_miss" ]; ck $? "  …and the recorder's OWN parser ACCEPTS that posted artifact (rc=$_bp_rc, ='${_bp_miss:-<accepted>}') - the false PASS, measured"
  grep -qF 'docs/ops/*.md' "$TMP/comment.md" 2>/dev/null; ck $? "  …carrying the contract's example files as the reviewer's evidence about THIS diff"
fi

# ⛔ THE ARM IS A PROVENANCE TEST, NOT A BAN ON QUOTES. A reviewer that WRITES ITS OWN claim still
# records, however it decorates it — otherwise the projection would trade one false PASS for a false
# BLOCK on every honest reviewer that quotes its own tool output.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: "this change only rewords docs/ops/self-healing-contract.md, and the seam it describes is asserted by §BP of tests/review-pr/run.sh"\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a QUOTED reason that is the reviewer's OWN still records (rc=$(rc_of)) - the arm refuses copies, not quotations"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written"
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| "`tests/review-pr/run.sh` §BP — a quoted copy is refused" | `_pb_rows=` emptied | §BP (mutant) | `❌ got rc=0` |\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a QUOTED row that is the reviewer's OWN still records (rc=$(rc_of)) - decoration does not make an authored row a copy"
reset
# ══ end §BP ══

# ── §BQ THE COPY THAT EDITS ONE CELL: PROVENANCE AT THE CELL, NOT AT THE ROW ──────────────────────
# ⛔ MEASURED AT 7bff1388d — the SEVENTH, EIGHTH and NINTH spelling of the same false PASS, and the
# class the whole-row arm structurally CANNOT see. `mutation_pasteback_rows` compares a row's WHOLE
# text, while the parser (`brief-gate.sh --mutation-missing`) asks only for a header naming the three
# columns plus ONE row of >= 3 cells — so a copy only has to keep the SHAPE. Measured on that head:
#   • the worked row with ONE CELL APPENDED (`| … | also verified |`) — ACCEPTED (rc=0, empty);
#   • the worked row with its LAST CELL DROPPED — the ordinary result of pasting a 4-column example
#     into a 3-column table (GFM wants header and delimiter to carry the same number of cells) —
#     ACCEPTED;
#   • the worked row PREFIXED with a word (`See: | `scripts/x.sh:120` … |`) — the leading text becomes
#     the first cell, the row is still >= 3 cells — ACCEPTED;
#   • the worked EXEMPTION extended by one clause of the reviewer's own (`… assertion and one more
#     clause`) — ACCEPTED, and an equality test on the payload misses it.
# All four minted `clean` on the harness's own example text, for a diff it says nothing about. The arm
# that closes them is provenance at the unit a reviewer actually copies — the CELL — plus containment
# for the single-line exemption; each assertion below FIRST asks the recorder's own parser (a copy is
# only a defect when the parser ACCEPTS it), then requires the seam to REFUSE, and the authored
# controls keep this a provenance test rather than a ban on mentioning the contract.
echo; echo "§BQ a copy that edits one CELL is still a copy — provenance at the cell, not the row"
_bq_hdr='| assertion | mutant (the edit that reverts the fix) | reddened row | observed |'
_bq_rule='|---|---|---|---|'
# The three edited-cell copies, BUILT FROM THE REAL `--mutation-section` row (never retyped): only the
# ONE edit each is made by this file, so the section cannot go stale as the contract changes.
_bq_extra="${CANON_ROW%|*} | also verified |"
_bq_drop="$(printf '%s' "$CANON_ROW" | awk -F'|' '{ OFS="|"; $5=""; print }')"
_bq_pref="See: ${CANON_ROW}"
for _k in extra drop pref; do
  _bq_ref="_bq_$_k"; _bq_row="${!_bq_ref}"
  printf '## MUTATION ATTRIBUTION\n\n%s\n%s\n%s\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" "$_bq_row" > "$TMP/bq-$_k.md"
  _bq_rc=0; _bq_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bq-$_k.md" 2>/dev/null)" || _bq_rc=$?
  [ "$_bq_rc" -eq 0 ] && [ -z "$_bq_miss" ]; ck $? "the parser ACCEPTS the worked row with the '$_k' edit (rc=$_bq_rc, ='${_bq_miss:-<accepted>}') - measured, so this is a live hole, not a hypothetical"
  reset; FIXTURE_NO_MUTATION=1
  printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n%s\n%s\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" "$_bq_row" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "11" ]; ck $? "  …and that '$_k' copy is REFUSED before anything is posted (rc=$(rc_of), want 11)"
  no_comment; ck $? "    …nothing posted as a review artifact ('$_k')"
  no_record; ck $? "    …and no record minted on the harness's own row ('$_k')"
  err_has "REPRODUCES THE CONTRACT'S OWN WORKED EXAMPLE ROW"; ck $? "    …with the refusal naming the provenance ('$_k')"
done
unset _k _bq_row
# The exemption's EXTENDED copy: the canonical payload with the reviewer's own clause after it.
_bq_pay="${CANON_EXEMPT#NO NEW ASSERTIONS: }"
_bq_ext="NO NEW ASSERTIONS: ${_bq_pay} and one more clause of my own"
printf '## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bq_ext" > "$TMP/bq-ext.md"
_bq_rc=0; _bq_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bq-ext.md" 2>/dev/null)" || _bq_rc=$?
[ "$_bq_rc" -eq 0 ] && [ -z "$_bq_miss" ]; ck $? "the parser ACCEPTS the worked exemption EXTENDED by a clause (rc=$_bq_rc, ='${_bq_miss:-<accepted>}')"
reset; FIXTURE_NO_MUTATION=1
printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bq_ext" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "  …and the EXTENDED copy of the worked exemption is REFUSED (rc=$(rc_of), want 11)"
no_record; ck $? "    …nothing recorded on the harness's own reason"
# ⛔ THE FALSE-BLOCK DIRECTION IS PROTECTED TOO, AND IT IS WHY THE TEST IS NOT SYMMETRIC: an honest
# reason that ends in the contract's own GENERIC TAIL (`… and no executable assertion`) is an authored
# sentence naming THIS diff's files, and a truncated-copy test would refuse it. Both authored controls
# below must still RECORD.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\nNO NEW ASSERTIONS: docs-only — this diff touches the new contract section and no executable assertion.\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "an AUTHORED reason sharing the contract's generic tail still records (rc=$(rc_of)) - the arm refuses copies, not phrasing"
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n%s\n%s\n| `tests/review-pr/run.sh` §BQ — a cell-edited copy is refused | `_pb_cells=` emptied | §BQ (authored) | `RED`, rc=11 |\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "an AUTHORED row that merely NAMES the contract's files still records (rc=$(rc_of)) - the arm counts canonical CELLS, so citing them is not a copy"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written"
# ⛔ THE FLOOR ITSELF, DRIVEN: ONE canonical cell is NOT a copy. A reviewer may legitimately reuse the
# example's OBSERVATION cell (the `❌ … REFUSED with 80 (got 0)`, rc=1 shape it prints) in a row of its
# own; refusing that would be the false block this floor exists to prevent. The cell is taken from the
# real contract row, so the arm is tested against the text it will actually meet.
reset; FIXTURE_NO_MUTATION=1
_bq_cell4="$(printf '%s' "$CANON_ROW" | awk -F'|' '{ print $5 }')"
printf '## MUTATION ATTRIBUTION\n\n%s\n%s\n| `tests/review-pr/run.sh` §BQ — the cell floor is two | `mv x y` | §BQ (floor) |%s|\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" "$_bq_cell4" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "ONE canonical cell reused in an otherwise AUTHORED row still records (rc=$(rc_of)) - the floor is two, and it is enforced on the output"
[ -f "$TMP/comment.md" ]; ck $? "  …because that artifact WAS posted (no refusal was taken)"
unset _bq_cell4
# ⛔ DISTINCT CELLS, NOT OCCURRENCES (P3 from the fresh-context review at 40d18e1a9). The rule this arm
# states is "ONE can appear honestly … two cannot" — a count of DISTINCT canonical cells. The helper
# prints one line per OCCURRENCE, so a canon that ships two rows sharing a distinctive cell (or one row
# that repeats one) listed that cell twice, and an AUTHORED row citing it ONCE counted two and was
# refused with exit 11: a false block whose cause is the harness's own example text, never the
# reviewer's claim. The fixture below is a fake gate on the seam's FIRST ladder rung serving exactly
# that canon (`tests/review-pr/run.sh` as a cell of BOTH data rows) and accepting any body that carries
# the heading, so the only thing under test is the count. The MUTANT that drops the dedupe must refuse
# the same transcript — otherwise this asserts the fixture, not the fix.
DED="$TMP/ded"; rm -rf "$DED"; mkdir -p "$DED/dist"
cp "$SRC" "$DED/dist/review-pr.sh"; chmod +x "$DED/dist/review-pr.sh"
cat > "$DED/dist/brief-gate.sh" <<'DEDGATE'
#!/usr/bin/env bash
case "${1:-}" in
  --mutation-section)
    cat <<'CANNON'

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `tests/review-pr/run.sh` | `mv a b` | §DED-ONE | `RED`, rc=1 |
| `tests/review-pr/run.sh` | `mv c d` | §DED-TWO | `RED`, rc=1 |
CANNON
    ;;
  --mutation-missing)
    _f="${2:-}"
    if [ "$_f" = "-" ]; then cat >/dev/null 2>&1; printf 'MUTATION-ATTRIBUTION\n'; exit 0; fi
    grep -q 'MUTATION ATTRIBUTION' "$_f" 2>/dev/null && exit 0
    printf 'MUTATION-ATTRIBUTION\n' ;;
esac
exit 0
DEDGATE
chmod +x "$DED/dist/brief-gate.sh"
_bq_ded_row='| `tests/review-pr/run.sh` | `mv x y` | §BQ (distinct) | `RED`, rc=1 |'
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n%s\n%s\n%s\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" "$_bq_ded_row" > "$TMP/reviewer-out"
run "$DED/dist/review-pr.sh" 2284
[ "$(rc_of)" = "0" ]; ck $? "a canon whose TWO rows share a distinctive cell does not double-count ONE honest citation (rc=$(rc_of), want 0)"
[ -f "$TMP/record-argv.txt" ]; ck $? "  …so the record is written: the arms judge the claim, not the harness's example text"
# …and the FIRST rung really was the fake gate (otherwise the shipped canon answered and this proves
# nothing about the shipped script). The canon cell must not be one the REAL contract also ships, or
# the count would be <= 1 anyway and the assertion would pass on the pre-fix code.
_canon_ded="$(bash "$DED/dist/brief-gate.sh" --mutation-section | grep -c 'tests/review-pr/run.sh')"
[ "$_canon_ded" = "2" ]; ck $? "  …the fixture really serves the cell TWICE (occurrences=$_canon_ded), so the pre-fix count was two"
DEDM="$DED/dist/review-pr-nodedupe.sh"
sed 's/ | sort -u)"/)"/' "$SRC" > "$DEDM"; chmod +x "$DEDM"
if cmp -s "$SRC" "$DEDM"; then
  fail "the dedupe mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf '## MUTATION ATTRIBUTION\n\n%s\n%s\n%s\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" "$_bq_ded_row" > "$TMP/reviewer-out"
  run "$DEDM" 2284
  [ "$(rc_of)" = "11" ]; ck $? "the MUTANT without the dedupe REFUSES that honest citation (rc=$(rc_of), want 11) - so the dedupe is what keeps the arm's stated floor"
  no_record; ck $? "  …and nothing was recorded on the false block"
fi
unset _bq_ded_row _canon_ded
# The internal mutant: WIDEN the cell arm's floor in a COPY, leaving everything else intact (the
# comparison, the projection and both other provenance arms). If the refusals above came from this arm,
# the copy must RECORD the cell-edited paste-back while the recorder's parser still accepts the artifact
# it publishes — the false PASS, measured end to end. The mutant is a FLOOR change and not a deleted
# arm because a deleted arm would also remove the message, while the floor is what the arm's own
# docstring promises: two canonical cells is a copy, one is not.
BQ="$TMP/mutant-cell-arm.sh"
sed 's/\[ "$_n" -ge 2 \] \&\& { printf/\[ "$_n" -ge 99 \] \&\& { printf/' "$SRC" > "$BQ"
if cmp -s "$SRC" "$BQ"; then
  fail "the cell-arm mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n%s\n%s\n\nCLEAN\n' "$_bq_hdr" "$_bq_rule" "$_bq_extra" > "$TMP/reviewer-out"
  run "$BQ" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT with the cell arm widened RECORDS the cell-edited paste-back (rc=$(rc_of)) - so the arm is what refuses it"
  _bq_rc=0; _bq_miss=""
  _bq_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/comment.md" 2>/dev/null)" || _bq_rc=$?
  [ "$_bq_rc" -eq 0 ] && [ -z "$_bq_miss" ]; ck $? "  …and the recorder's OWN parser ACCEPTS that posted artifact (rc=$_bq_rc, ='${_bq_miss:-<accepted>}') - the false PASS, measured"
fi
reset
# ══ end §BQ ══

# ── §BS THE EXEMPTION'S STATED LIMIT: AN INTERIOR-EDITED COPY RECORDS, AND THAT IS PINNED ────────
# ⛔ THIS SECTION ASSERTS A RECORD, NOT A REFUSAL, AND THAT IS DELIBERATE (agent-infra#3987).
# The provenance arms close every copy whose refusal is UNAMBIGUOUS: the fenced echo, the indented
# one, the row verbatim, the row with a cell added / dropped / prefixed, the verbatim exemption and
# the exemption EXTENDED by a clause. What they do NOT close is an exemption reason that is the
# contract's worked example with an INTERIOR edit — one word deleted, the first word changed, one
# word substituted, or its opening dropped — because every rule that would refuse those also refuses
# the natural way an honest docs-only reviewer writes the SAME claim ("docs-only — the diff touches
# docs/ops/<this diff's file>.md"). MEASURED through this seam at f4a345126, not through a helper
# (the round that measured one ARM of the composition and "found" a hole the gate already refused is
# why this drives `run`): all four edited shapes exit 0 and mint a record; the verbatim line exits 11;
# and BOTH honest phrasings — the truncated one naming the glob, and the full one naming a real file —
# exit 0 as well. So the boundary sits between "retyped exactly" and "edited", and a single-granularity
# text rule cannot move it without taking the honest sentence with it: a word-run rule ("six contiguous
# canonical words is a copy") refuses `docs-only — the diff touches docs/ops/self-healing-contract.md
# and no executable assertion.`, which is an authored reason about THIS diff.
# ⛔ WHY THE RESIDUAL IS ACCEPTED RATHER THAN CLOSED (the same judgement §BQ's floor makes one arm
# over): the exemption names NO assertion. A pasted ROW mints a specific false claim — `scripts/x.sh:120`
# was reverted by that mutant and went red — about an assertion this diff does not contain, which is the
# fabricated-evidence class #3442 exists for. An edited EXEMPTION still says only "this diff adds no
# assertion", which is the reviewer's judgement either way; no text rule can make that judgement
# correct, because the recorder deliberately never looks at the diff. Refusing the honest sentence to
# narrow a vague one is the false block this file pays for everywhere else.
# ⛔ SO THIS IS A PIN, IN BOTH DIRECTIONS: a future round that ADDS a rule narrowing the limit reddens
# the first four scenarios, and a future round that REFUSES the natural phrasing reddens the last two.
# Neither can land silently, and neither can land claiming the other is unaffected.
echo; echo "§BS the exemption's stated limit: an INTERIOR-EDITED copy records, and the honest phrasing does too"
# Every shape is DERIVED from the contract's own text (`$CANON_EXEMPT`), never re-typed: a fixture that
# re-spells the example becomes a second, drifting definition of the thing under test.
_bs_del="$(printf '%s' "$CANON_EXEMPT" | sed 's/ touches / /')"
_bs_fst="$(printf '%s' "$CANON_EXEMPT" | sed 's/docs-only/Documentation-only/')"
_bs_sub="$(printf '%s' "$CANON_EXEMPT" | sed 's/ and no executable/ with no executable/')"
_bs_pre="$(printf '%s' "$CANON_EXEMPT" | sed 's/^NO NEW ASSERTIONS: docs-only — /NO NEW ASSERTIONS: /')"
# The two honest phrasings a docs-only reviewer actually writes.
_bs_glob="$(printf '%s' "$CANON_EXEMPT" | sed 's/ and no executable assertion\.$//')"
_bs_real="$(printf '%s' "$CANON_EXEMPT" | sed 's|`docs/ops/\*\.md`|docs/ops/self-healing-contract.md|')"
# A derivation that silently did not apply would make the loop below assert the CANONICAL line (already
# refused) four times — every scenario green for the wrong reason. Tripwired, as the mutants are.
_bs_bad=0
[ "$_bs_del" != "$CANON_EXEMPT" ] || _bs_bad=1
[ "$_bs_fst" != "$CANON_EXEMPT" ] || _bs_bad=1
[ "$_bs_sub" != "$CANON_EXEMPT" ] || _bs_bad=1
[ "$_bs_pre" != "$CANON_EXEMPT" ] || _bs_bad=1
[ "$_bs_glob" != "$CANON_EXEMPT" ] || _bs_bad=1
[ "$_bs_real" != "$CANON_EXEMPT" ] || _bs_bad=1
[ "$_bs_bad" -eq 0 ]; ck $? "all six shapes are DERIVED from the contract's own text (a no-op edit would assert the canonical line, already refused)"
# …and each stays a LIVE exemption: a derivation that stripped the `NO NEW ASSERTIONS:` LABEL would make
# the parser refuse it for MUTATION-MUTANT-COLUMN instead of judging the payload, so the scenario would
# assert a refusal for a reason the pin does not claim (measured on the first draft of `pre`).
_bs_bad=0
for _b in del fst sub pre glob real; do
  _bs_ref="_bs_$_b"
  case "${!_bs_ref}" in "NO NEW ASSERTIONS: "*) ;; *) _bs_bad=1 ;; esac
done
unset _b _bs_ref
[ "$_bs_bad" -eq 0 ]; ck $? "  …and every one still carries the \`NO NEW ASSERTIONS:\` LABEL, so each is judged on its PAYLOAD, not on a stripped label"
for _b in del fst sub pre; do
  _bs_ref="_bs_$_b"; _bs_line="${!_bs_ref}"
  printf '## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bs_line" > "$TMP/bs-$_b.md"
  _bs_rc=0; _bs_miss="$(bash "$GATE_SH" --mutation-missing "$TMP/bs-$_b.md" 2>/dev/null)" || _bs_rc=$?
  [ "$_bs_rc" -eq 0 ] && [ -z "$_bs_miss" ]; ck $? "the parser ACCEPTS the worked reason with the '$_b' edit (rc=$_bs_rc, ='${_bs_miss:-<accepted>}') - so this is a live copy the arms do not read"
  reset; FIXTURE_NO_MUTATION=1
  printf 'I edited the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bs_line" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  …and the '$_b' edit RECORDS (rc=$(rc_of)) - the STATED LIMIT, pinned: no rule close enough to refuse it leaves the honest phrasing alone"
  [ -f "$TMP/record-argv.txt" ]; ck $? "    …with a record minted ('$_b'): the limit is a recorded behaviour, not a broken arm"
  err_not_has "PASTE-BACK"; ck $? "    …and no provenance refusal fired ('$_b'), so the arms behave exactly as documented"
done
unset _b _bs_ref _bs_line
# The other side of the pin: the VERBATIM line must still be refused, by the provenance arm. Without
# this, a round could "close the limit" by deleting the arm and leave the four scenarios above green.
reset; FIXTURE_NO_MUTATION=1
printf 'Here is the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$CANON_EXEMPT" > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "the VERBATIM worked reason is still REFUSED (rc=$(rc_of), want 11) - the limit is about EDITS, not about the arm being gone"
no_record; ck $? "  …nothing recorded on the harness's own reason"
err_has "REPUBLISHES THE CONTRACT'S OWN WORKED"; ck $? "  …with the refusal naming the provenance, so §BS's green asserts an arm that still exists"
# ⛔ THE FALSE-BLOCK SIDE, ASSERTED BECAUSE IT IS THE REASON THE LIMIT EXISTS. Both sentences below
# are authored claims about THIS diff: the first is the natural truncation (the diff touches the glob),
# the second is the same claim with the file actually read named. A word-run or similarity rule narrow
# enough to refuse the four edits above refuses these too, so these two are the tripwire that stops it.
for _b in glob real; do
  _bs_ref="_bs_$_b"; _bs_line="${!_bs_ref}"
  reset; FIXTURE_NO_MUTATION=1
  printf '## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bs_line" > "$TMP/reviewer-out"
  run "$SRC" 2284
  [ "$(rc_of)" = "0" ]; ck $? "an AUTHORED '$_b' reason still records (rc=$(rc_of)) - the FALSE BLOCK any narrower rule would take with it"
  [ -f "$TMP/record-argv.txt" ]; ck $? "  …and the record is written ('$_b')"
done
unset _b _bs_ref _bs_line
# ⛔ THE PIN IS LOAD-BEARING, DRIVEN: a COPY of the script with the limit NARROWED — every exemption
# reason naming the contract's own glob is refused — must redden BOTH directions at once. If it did
# not, §BS's green would be decoration (a scenario that cannot fail pins nothing), and the coupling
# this section asserts (closing the four edits costs the honest sentence) would be an opinion rather
# than a measurement. The narrowing is four lines in the exemption arm and nothing else, so the two
# scenarios below are its only possible cause of refusal.
BS="$TMP/mutant-limit-narrowed.sh"
# ONE line replaced, nothing else: the exemption arm's read loop gains a check that refuses any reason
# naming the contract's own glob. Written as a single-line compound so no sed newline escape is needed
# (BSD sed does not read `\n` in a replacement as a newline, and this suite runs on macOS too).
sed 's#^  while IFS= read -r _ec; do$#  { printf %s "${1:-}" | grep -qF "docs/ops/*.md" \&\& { printf "narrowed"; return 0; }; }; while IFS= read -r _ec; do#' "$SRC" > "$BS"
if cmp -s "$SRC" "$BS"; then
  fail "the limit-narrowing mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf 'I edited the shape I was given:\n\n## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bs_del" > "$TMP/reviewer-out"
  run "$BS" 2284
  [ "$(rc_of)" = "11" ]; ck $? "the NARROWED copy REFUSES the 'del' edit (rc=$(rc_of), want 11) - so the four scenarios above are load-bearing, not decoration"
  reset; FIXTURE_NO_MUTATION=1
  printf '## MUTATION ATTRIBUTION\n\n%s\n\nCLEAN\n' "$_bs_glob" > "$TMP/reviewer-out"
  run "$BS" 2284
  [ "$(rc_of)" = "11" ]; ck $? "  …AND refuses the AUTHORED 'glob' reason (rc=$(rc_of), want 11) - the coupling, measured: closing the edits costs the honest sentence"
fi
reset
# ══ end §BS ══

# ── §BT THE MIRROR MIRRORS ALL THREE ARMS, NOT ONE (agent-infra#3987, P3 at a8767f401) ─────────────
# ⛔ WHY THIS SECTION EXISTS. §BL proves the seam mirrors record-review.sh's arm (1) — the Step-8
# stalled/capped marker. The recorder scans its evidence body with TWO MORE arms that this seam would
# still publish into: the `[ADVERSARIAL-BOUND]` trigger (`:2091`), whose arm (iii) REFUSES a marker line
# with no `residuals=` field; and the `Outcome:` declaration arms (1a `:2216`, 1c `:1618`). A mutation
# row that merely NAMES the disclosure token, or that quotes a blocking `Outcome:` declaration, is
# lexically the thing those arms refuse — so the artifact was published and the RECORD step then
# refused it, after the review was paid for. That is the same #1964 false-diagnosis shape §BL closes for
# one arm and left open for the other two.
echo; echo "§BT the pre-post mirror covers ALL of the recorder's body-scanning arms"

# (1) THE DISCLOSURE TOKEN NAMED WITHOUT ITS MANDATORY FIELD IS REFUSED PRE-POST.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/q.sh:3` — the bounded scan stops at the declared threat surface | `mv g q` | `q.test.sh` §A | `RED`, rc=1 |\n\nThe lane writes that marker [ADVERSARIAL-BOUND] into its report when it caps.\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "11" ]; ck $? "a row that NAMES [ADVERSARIAL-BOUND] with no 'residuals=' field refuses PRE-POST (rc=$(rc_of), want 11) — the recorder's arm (iii) would refuse it AFTER it was published"
err_has "no 'residuals=' field"; ck $? "  …naming the missing field, so the operator is not sent to read the recorder"
no_record; ck $? "  …nothing recorded"
case "$(cat "$TMP/comment.md" 2>/dev/null)" in *ADVERSARIAL-BOUND*) rc=1;; *) rc=0;; esac
ck $rc "  …and NOTHING was posted: the artifact record-review.sh would reject is not on the PR"

# (2) ARM (1a)/(1c): THE `Outcome:` DECLARATIONS. ⛔ DRIVEN AS A UNIT, DELIBERATELY. Any end-to-end
# fixture carrying a blocking declaration of the shape the recorder reads also carries a COUNT of
# "blocking findings", which the seam's OWN prose findings-scanner sees several hundred lines upstream —
# the verdict flips to `issues` (rc=7) and the pre-post scan never runs, so the end-to-end arm would
# measure the WRONG GATE. `recorder_veto2_hit` is the exact function the seam calls, extracted from the
# script under test, so this asserts the mirror's decision and (3) below asserts the wiring is
# load-bearing. On the pre-fix script the function does not exist, so the extraction fails here.
V2="$TMP/veto2-unit.sh"
{
  grep -E '^_RECORDER_(OC_NBSP|OC_DECL_RE|VETO2_(NONCLEAN|BLOCKING|FIXED)_RE|AB_TOKEN_RE|AB_FIELD_RE)=' "$SRC"
  sed -n '/^recorder_veto2_hit() {/,/^}$/p' "$SRC"
} > "$V2" 2>/dev/null
grep -q '^recorder_veto2_hit() {' "$V2" 2>/dev/null; ck $? "the mirror is a callable unit in the script under test (on the pre-fix script there is none)"
if grep -q '^recorder_veto2_hit() {' "$V2" 2>/dev/null; then
  # shellcheck disable=SC1090
  . "$V2"
  v2hit() { printf '%s\n' "$1" > "$TMP/v2case.txt"; recorder_veto2_hit "$TMP/v2case.txt"; }
  [ -n "$(v2hit '**Outcome: 2 blocking findings remain open.**')" ]; ck $? "arm (1c): a blocking-noun Outcome: declaration is REFUSED"
  [ -n "$(v2hit '**Outcome: CLEAN — 1 P1 (dispatch guard) remains open.**')" ]; ck $? "arm (1c): a live P1 count is REFUSED too (the severity spelling, measured ADMITTED before #3902's fix)"
  [ -n "$(v2hit '**Outcome: not-clean**')" ]; ck $? "arm (1a): a non-clean Outcome: declaration is REFUSED"
  [ -z "$(v2hit '**Outcome: clean**')" ]; ck $? "NO FALSE BLOCK: the artifact's own '**Outcome: clean**' passes — the mirror cannot refuse every review"
  [ -z "$(v2hit '**Outcome: CLEAN — 2 blocking findings were fixed**')" ]; ck $? "NO FALSE BLOCK: the recorder's ESCAPE — a count followed by 'fixed' is admitted — is carried by the mirror"
  # ⛔ THIS ONE IS AN AGREEMENT TEST, NOT A BARE "REFUSE": prose carrying an `outcome:` label is read as a
  # declaration BY THE RECORDER (its anchor is `(^|[^[:alnum:]])outcome`, which `an outcome:` satisfies),
  # so the mirror refusing it is faithful rather than a widening. Asserting the two AGREE is the property
  # — a bare `-n` would also pass if the mirror refused everything.
  # ⛔ A HERE-STRING, NEVER `printf … | grep -q` (#841/#864, the same idiom the seam's own arm was
  # caught on): under `pipefail` the quiet grep exits at its first match, the writer takes SIGPIPE and
  # the pipeline reports 141 — so the agreement probe could read the recorder as NOT matching and
  # assert the mirror is faithful to the wrong answer. (`run.sh` is outside
  # `scripts/check-no-sigpipe-grep.sh`'s default roots, so nothing else would redden this.)
  _v2_prose='the review discussed an outcome: it was blocking, 2 P1 remain open'
  grep -qiE "$_RECORDER_OC_DECL_RE" <<<"$_v2_prose"; _v2_rec=$?
  { [ -n "$(v2hit "$_v2_prose")" ] && [ "$_v2_rec" -eq 0 ]; }; ck $? "the mirror AGREES with the recorder's own anchor on prose carrying an 'outcome:' label (recorder matches: $([ "$_v2_rec" -eq 0 ] && echo yes || echo no)) — not a widening"
  unset -f v2hit
fi
reset

# (3) ⛔ THE OTHER DIRECTION: THE MIRROR MUST NOT FALSE-BLOCK. Three artifacts the recorder ACCEPTS
# must still record. A false refusal here costs a paid review, which is the direction this file
# protects against everywhere else — so the escape and the well-formed disclosure are PINNED, not
# assumed.
reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/q.sh:3` — the bounded scan stops at the declared threat surface | `mv g q` | `q.test.sh` §A | `RED`, rc=1 |\n\n[ADVERSARIAL-BOUND] cycles=2 threats=3 covered=3 residuals=none\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a WELL-FORMED disclosure (with 'residuals=') still RECORDS (rc=$(rc_of)) — a legitimate capped review is not refused by the new mirror"

reset; FIXTURE_NO_MUTATION=1
printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/q.sh:3` — the guard reads the declaration literally | `mv g q` | `q.test.sh` §A | `RED`, rc=1 |\n\n**Outcome: CLEAN — 2 blocking findings were fixed, 0 remain.**\n\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "…and the recorder's ESCAPE still records: a count followed by 'fixed' is admitted, so mirroring arm (1c) does not over-block it (rc=$(rc_of))"

# (4) NON-VACUITY: the arms above are the MIRROR's doing, not something else refusing first.
BT="$TMP/mutant-no-veto2-scan.sh"
cp "$SRC" "$BT"; chmod +x "$BT"
sed 's|^  _vt2_line=.*|  _vt2_line=""|' "$SRC" > "$BT"
if cmp -s "$SRC" "$BT"; then
  fail "the veto2-scan mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  printf '## MUTATION ATTRIBUTION\n\n| assertion | mutant (the edit that reverts the fix) | reddened row | observed |\n|---|---|---|---|\n| `tests/q.sh:3` — the bounded scan stops at the declared threat surface | `mv g q` | `q.test.sh` §A | `RED`, rc=1 |\n\nThe lane writes that marker [ADVERSARIAL-BOUND] into its report when it caps.\n\nCLEAN\n' > "$TMP/reviewer-out"
  run "$BT" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT without the mirror POSTS it (rc=$(rc_of)) - so the pre-post scan is what refuses it, not an earlier gate"
  grep -qiE '\[ADVERSARIAL-BOUND\]' "$TMP/comment.md" 2>/dev/null; ck $? "  …the disclosure token reaches the published evidence body, where the recorder's arm (iii) would refuse it"
fi
reset

# (5) THE MIRROR CANNOT DRIFT SILENTLY. There is no way to import a regexp from another script, so the
# copy is pinned: the seam's `Outcome:` recogniser must be the recorder's OWN regex after variable
# expansion (the strongest form of the §BL(3) tripwire), and the two literals the other arm reads must
# still be present in the recorder.
REC_OCL="$(grep -E '^OC_DECL_RE="' "$ROOT/scripts/record-review.sh" 2>/dev/null | head -1)"
REC_OC_PAT="$(OC_NBSP=$'\xc2\xa0'; eval "$REC_OCL"; printf '%s' "${OC_DECL_RE:-}")"
SEAM_OCL="$(grep -E '^_RECORDER_OC_DECL_RE="' "$SRC" 2>/dev/null | head -1)"
# ⛔ THE SEAM'S REGEX REFERENCES ITS OWN NBSP VARIABLE, so it must be defined before the eval or
# `set -u` aborts the comparison and the tripwire silently reports a DIFFER from an unset variable.
_RECORDER_OC_NBSP=$'\xc2\xa0'
SEAM_OC_PAT="$(eval "$SEAM_OCL"; printf '%s' "${_RECORDER_OC_DECL_RE:-}")"
[ -n "$REC_OC_PAT" ]; ck $? "the recorder's OC_DECL_RE is still extractable from record-review.sh (the mirror's source of truth)"
[ -n "$SEAM_OC_PAT" ] && [ "$SEAM_OC_PAT" = "$REC_OC_PAT" ]; ck $? "…and the seam's expanded copy is IDENTICAL to it (seam='$SEAM_OC_PAT')"
grep -qF '\[ADVERSARIAL-BOUND\]' "$ROOT/scripts/record-review.sh" 2>/dev/null; ck $? "…the adversarial-bound token the mirror refuses is still one the recorder triggers on"
grep -qF 'residuals=[[:space:]]*' "$ROOT/scripts/record-review.sh" 2>/dev/null; ck $? "…and 'residuals=' is still the field its arm (iii) demands (the recorder still extracts `residuals=[[:space:]]*…`), so the mirror's refusal condition still matches"
# ══ end §BT ══

# ── §BU THE MARKER SUPPLIES AN **ISSUES** VERDICT — AND NEVER A CLEAN ONE (agent-infra#4233) ─────
# ⛔ WHY THIS SECTION EXISTS. `review-pr.sh` answered `no verdict from the reviewer — re-run` for a run
# whose reviewer had emitted a COMPLETE, machine-readable verdict — `REVIEW_VERDICT: ISSUES` /
# `FINDINGS_BLOCKING: 3` — with rc=0, 599 s, a finished reviewer and three named [P2] findings. All of
# them were discarded. `VWORD` is derived only from the last PROSE verdict-shaped line, so a reviewer
# that concluded with exactly the block this file's prompt demands, and no separate `CLEAN` /
# `ISSUES <n>` line, had no verdict at all — and the operator was told to re-run into the same discard.
# The SAME block had been called `a self-contradicting CLEAN verdict` one round earlier (a prose CLEAN
# over it), i.e. one input shape, two names, and neither named the lines it had matched.
# ⛔ THE #2670 DECISION IS NOT WEAKENED, AND (4) BELOW IS ITS PIN: the marker may QUALIFY a verdict, and
# now may SUPPLY the REFUSAL direction (`ISSUES`), which records nothing — never `CLEAN`. A restated
# contract block still mints nothing (§AQ(5b)), and `ISSUES` over a zero still supplies nothing.
echo; echo "§BU the marker supplies an ISSUES verdict (agent-infra#4233) — and never a clean one"

# (1) THE ISSUE'S OWN ACCEPTANCE CASE: marker-only, ISSUES over 3 => ISSUES, findings printed, no record.
reset; FIXTURE_NO_MARKER=1
printf '[P2] .github/workflows/portability-tree-scan.yml:161-163 — the title parser reads the wrong field\n[P2] .github/workflows/portability-tree-scan.yml:131 — n is grep -c\n[P2] scripts/check-portability-scope.test.sh:511-522 — C7 does not test the pipeline it claims to\n\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 3\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "marker-only 'REVIEW_VERDICT: ISSUES' + 'FINDINGS_BLOCKING: 3' is an ISSUES verdict, not 'no verdict' (rc=$(rc_of), agent-infra#4233)"
no_record; ck $? "  ...nothing recorded — the marker may only ever supply the REFUSAL direction"
err_not_has "NO VERDICT"; ck $? "  ...and the paid review is not discarded as a reviewer failure"
err_has "STRUCTURED verdict marker reports 3 blocking finding(s)"; ck $? "  ...the refusal names the COUNT the marker carried"
err_has "marker line: REVIEW_VERDICT: ISSUES"; ck $? "  ...and the marker line, so the reader is not left with an oracle"
out_has "the title parser reads the wrong field"; ck $? "  ...and the three findings are PRINTED (they were lost before: no fixer ever saw them)"

# (2) MUTATION CONTROL: the arm is what makes (1) pass. Force the flag off and the SAME transcript is
# the old exit 6 — so (1) cannot be satisfied by some other widening landing underneath it.
BU="$TMP/mutant-no-marker-issues.sh"
sed 's/^  MK_ISSUES_BLOCK=1$/  MK_ISSUES_BLOCK=0/' "$SRC" > "$BU"
if cmp -s "$SRC" "$BU"; then
  fail "the marker-supplies-ISSUES mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MARKER=1
  printf '[P2] a.sh:1 - x\n[P2] b.sh:2 - y\n\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 2\n' > "$TMP/reviewer-out"
  run "$BU" 2284
  [ "$(rc_of)" = "6" ]; ck $? "the MUTANT without the arm answers 6 again (rc=$(rc_of)) - so the arm is what reads the marker, not an earlier gate"
  no_record; ck $? "  ...and records nothing either way"
fi

# (3) THE BLOCK MUST BE A BLOCK, NOT TWO SCATTERED LINES: a count line BEFORE the verdict field cannot
# be assembled into a conclusion, and the refusal says exactly what it read (issue #4233, part 2).
reset; FIXTURE_NO_MARKER=1
printf 'FINDINGS_BLOCKING: 3\nsome prose in between\nREVIEW_VERDICT: ISSUES\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a count line ABOVE the verdict field does not supply a verdict (rc=$(rc_of)) — the prompt puts the block after it"
no_record; ck $? "  ...nothing recorded"
err_has "WHAT THIS PARSER READ"; ck $? "  ...and the refusal prints WHAT IT READ instead of asserting an absence"
err_has "FINDINGS_BLOCKING line     : FINDINGS_BLOCKING: 3"; ck $? "  ...including the count line it matched"
err_has "blind re-run reproduces"; ck $? "  ...and does not send the operator into the same 10-minute discard"

# (4) ⛔ THE ANTI-FAIL-OPEN PIN — THE ONE DIRECTION THE MARKER MAY NEVER SUPPLY. `ISSUES` over a ZERO is
# the same statement as `ISSUES 0`, which is CLEAN; letting the marker supply THAT would be the measured
# #2670 fail-open (a restatement minting a signed clean record). It must still be exit 6, no record.
reset; FIXTURE_NO_MARKER=1
printf 'my notes\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "'REVIEW_VERDICT: ISSUES' over FINDINGS_BLOCKING: 0 supplies NO verdict (rc=$(rc_of), want 6) - the marker cannot grant clean"
no_record; ck $? "  ...nothing recorded"
err_has "marker verdict / count read: issues / 0"; ck $? "  ...and the refusal names the fields it decoded, so 'nothing' and 'zero' are distinguishable"

# (4b) A QUOTED marker supplies nothing either — the marker is read from the same fence-filtered region as
# the prose verdict, so repeating somebody else's ISSUES block cannot become a conclusion.
reset; FIXTURE_NO_MARKER=1
printf 'An earlier head already carried this:\n```\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 3\n```\nI could not complete the deep pass.\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "6" ]; ck $? "a FENCED ISSUES marker is a quotation, never a verdict (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"

# (5) ONE INPUT SHAPE, ONE OUTCOME: a prose CLEAN over the same block reaches the SAME diagnosis through
# the SAME function, instead of a second name for the same conclusion.
reset; FIXTURE_NO_MARKER=1
printf '[P2] a.sh:1 - x\nCLEAN\n\nREVIEW_VERDICT: ISSUES\nFINDINGS_BLOCKING: 3\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a prose CLEAN over a marker reporting 3 blockers is an ISSUES review (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
err_has "STRUCTURED verdict marker reports 3 blocking finding(s)"; ck $? "  ...reported by the SAME diagnosis the no-prose-line arm uses (one shape, one name)"

# (5b) ANTI-WALL: the conversion must NOT swallow the CLEAN-side contradiction arm. A marker that says
# `CLEAN` over a NON-ZERO count is not the ISSUES direction and stays its own refusal (§AQ(2)).
reset; FIXTURE_NO_MARKER=1
printf 'CLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 7\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "'REVIEW_VERDICT: CLEAN' over FINDINGS_BLOCKING: 7 is still refused as a contradiction (rc=$(rc_of))"
no_record; ck $? "  ...nothing recorded"
err_has "marker reports 7 blocking finding(s) while the verdict is CLEAN"; ck $? "  ...by its OWN arm, not by the ISSUES conversion"

# (6) ANTI-WALL, THE OTHER WAY: the ordinary clean path still records, through the marker, unchanged.
reset; FIXTURE_NO_MARKER=1
printf 'Nothing blocks.\nCLEAN\n\nREVIEW_VERDICT: CLEAN\nFINDINGS_BLOCKING: 0\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "a marker saying CLEAN over a zero still RECORDS (rc=$(rc_of))"
grep -q '"verdict":"clean"' "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "  ...verdict=clean, bound to the reviewed head"
rm -f "$BU"; reset
# ══ end §BU ══

# ── §BV A QUOTED ASSERTION IS NOT A FINDING THE REVIEWER REPORTED (agent-infra#4233, reopened) ────
# ⛔ WHY THIS SECTION EXISTS. #4234 fixed ONE verdict shape (the marker-only `REVIEW_VERDICT: ISSUES`
# block, §BU). #4251 then hit a SECOND shape on the SAME deployed parser, and `review-pr.sh` answered
# `a self-contradicting CLEAN verdict (clean + a reported count) is never recorded`. The measured
# input (preserved verbatim in /tmp/aiv99-4251.log; the transcript it names,
# /tmp/review-pr-4251.Qo3hv5/reviewer.log, has since been swept — which is exactly why the line lives
# in this suite as a fixture now):
#
#   | `scripts/activate-harness.test.sh:581` — "no shipped template is an unmapped declaration error"
#     | drop `\|eldato-disk-reaper-cache` from `installer_for()` | T1 `:581` | … |
#
#   …and the fragment the classifier printed for it, byte for byte: ` an unmapped declaration error`.
#   That is a mutation-table row — a REQUIRED section of the reviewer's own artifact — quoting the TEST
#   ASSERTION it names. The article arm read the quoted noun phrase as a count of one live finding.
# ⛔ WHAT IS AND IS NOT CLAIMED HERE. The original #4251 transcript is gone, so this section does NOT
# claim to have re-fed it; it feeds the MEASURED LINE, verbatim, and asserts the classifier no longer
# invents a finding from a quotation. Whether that transcript's true verdict was CLEAN or ISSUES is
# settled DOWNSTREAM, not here: if it really carried [P1]/[P2] lines the severity scanner refuses it
# whatever this arm does — so this fix cannot convert a refusal into a passed review.
# ⛔ AND THE BLANKING IS CONFINED TO WHAT THE MEASURED CASE ACTUALLY IS: A MUTATION-TABLE ROW (P1, fresh
# review at `f3875382b204`). Blanking every quotation turned a STATED count on ordinary prose into no
# finding — a signed clean over a stated blocker, which §BV(7) now pins as a REFUSAL and §BV(8) shows
# going green again only when every line is blanked. The residual left is table-row-only, and §BV pins
# its recording side ((1)) and its refusal side ((4), (4b)) so it cannot move silently in either direction.
# ⛔ AND THE SECOND HALF OF THE ISSUE: the reader must not BLAME the reviewer for its own unparseable
# input. `self-contradicting` now requires a verdict-shaped offending line (a line really cannot be
# both); a count on an ORDINARY line is reported as unreconciled, with both lines printed.
echo; echo "§BV a quoted assertion is not a reported finding (agent-infra#4233, reopened — the #4251 shape)"

# (1) THE ISSUE'S ACCEPTANCE CASE: the measured #4251 row, in the mutable section, still records CLEAN.
reset; FIXTURE_NO_MUTATION=1
cat > "$TMP/reviewer-out" <<'BVMEASURED'
## MUTATION ATTRIBUTION

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `scripts/activate-harness.test.sh:581` — "no shipped template is an unmapped declaration error" | drop `\|eldato-disk-reaper-cache` from `installer_for()` | T1 `:581` | author-measured pre-fix output carries `DECLARATION ERROR … must UNKNOWN`; UNVERIFIED here — `bash scripts/activate-harness.test.sh` |

CLEAN
BVMEASURED
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "the measured #4251 mutation row no longer invents a finding: the review RECORDS (rc=$(rc_of), want 0)"
[ -f "$TMP/record-argv.txt" ]; ck $? "  ...a record was written, so a paid review is not discarded over a quotation"
err_not_has "self-contradicting"; ck $? "  ...and nothing in the run asserts the reviewer contradicted itself"

# (2) MUTATION CONTROL: the blanking is what makes (1) pass. Remove it entirely and the SAME transcript
# is the pre-fix refusal again, naming the pre-fix fragment byte for byte.
BV="$TMP/mutant-no-unquote.sh"
# ⛔ THE MUTANT THAT REVERTS THE FIX IS NOW "NO BLANKING AT ALL" (P1, fresh review at
# `f3875382b204`): the old control flipped `_quote_ok`, which no longer exists — ONE blanking rule
# governs every line — so the mutation neutralises the call itself. It must apply exactly once, and
# `cmp -s` below fails the suite loudly if a later edit moves the call out from under this control.
sed 's/^  line = unquote(line)$/  line = line/' "$SRC" > "$BV"
if cmp -s "$SRC" "$BV"; then
  fail "the unquote mutation did not apply - this control proves NOTHING"
else
  reset; FIXTURE_NO_MUTATION=1
  cat > "$TMP/reviewer-out" <<'BVMEASURED'
## MUTATION ATTRIBUTION

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `scripts/activate-harness.test.sh:581` — "no shipped template is an unmapped declaration error" | drop `\|eldato-disk-reaper-cache` from `installer_for()` | T1 `:581` | author-measured pre-fix output carries `DECLARATION ERROR … must UNKNOWN`; UNVERIFIED here — `bash scripts/activate-harness.test.sh` |

CLEAN
BVMEASURED
  run "$BV" 2284
  [ "$(rc_of)" = "7" ]; ck $? "the MUTANT without the blanking refuses the same row again (rc=$(rc_of), want 7) - so the blanking is load-bearing"
  err_has "an unmapped declaration error"; ck $? "  ...naming the SAME fragment the pre-fix seam printed (the fixture reproduces the reported defect, not a lookalike)"
  no_record; ck $? "  ...nothing recorded either way"
fi

# (3) ⛔ THE VERDICT-SHAPED CHANNEL IS UNTOUCHED BY THE BLANKING: the gate inside `unquote` admits a
# MUTATION-TABLE ROW and nothing else, and a verdict line can never be a table row (every VD_* pattern
# is anchored at `^[[:space:]]*` on a CLEAN/ISSUES/`Verdict:` token, while a table row begins `|`). So
# `CLEAN — "3 blocking defects …"` is read exactly as the pre-#4253 seam read it, on every pass.
reset; printf '**Verdict:** CLEAN — "3 blocking defects in the parser".\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a verdict-shaped line QUOTING a count is still refused (rc=$(rc_of), want 7) - blanking cannot un-refuse the verdict channel"
no_record; ck $? "  ...nothing recorded"
err_has "self-contradicting"; ck $? "  ...and THIS one really is self-contradicting, so it keeps that name"
err_has "The count sits ON the verdict-shaped line above"; ck $? "  ...and the message says the count is ON that one line, which is what makes it contradictory"

# (4) ⛔ AND A QUOTATION THAT ITSELF SAYS THE FINDING IS LIVE IS NOT BLANKED — INSIDE the blanking path,
# which is why the fixture is a TABLE ROW (the only line class the blanking touches now; the same line as
# prose would be unblanked and would refuse for a reason this row could not attribute). A reviewer that
# smuggles its blocker into quotes still gets refused by the quotation's own words.
reset; printf '| assertion "2 blocking defects remain in the parser" | x |\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a quoted phrase saying the defects REMAIN is still a finding (rc=$(rc_of), want 7)"
no_record; ck $? "  ...nothing recorded"

# (4b) ⛔ THE CUE THAT GOVERNS A QUOTATION OFTEN SITS OUTSIDE IT (P2, fresh review at `0dd5e5519` —
# MEASURED at the pre-fix blanking, on the head this row was added for): `unquote()` tested the
# LIVENESS CUE inside the span only, so
#
#   The suite reports "2 blocking defects" still open.
#
# produced NO fragment — i.e. the pass RECORDED A SIGNED CLEAN over a review that had reported a live
# count with its own cue sitting on the predicate outside the quotes. The window is the quotation AND
# the clause that carries it, bounded by a sentence terminator or a table-cell separator.
# ⛔ THE FIXTURE IS A TABLE ROW SO THE WINDOW IS STILL THE ONLY THING DECIDING IT (P1, fresh review at
# `f3875382b204`): as prose the line is no longer blanked at all, so it would refuse for a reason this
# row cannot attribute. As a row, the span-to-cell window is what keeps the count alive.
# ⚠️ NON-VACUITY: RED at `896b4a96` (the head that carries the defect) and GREEN after the window fix;
# it also goes RED under `win = span` (blanking on the span's own words), which is what pins the window.
reset; printf '| the suite reports "2 blocking defects" still open |\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a quoted count whose LIVENESS CUE is outside the quotation still refuses (rc=$(rc_of), want 7)"
no_record; ck $? "  ...nothing recorded, so no signed clean is minted over it"
err_has '2 blocking defects'; ck $? "  ...and the count it refused over is printed, not swallowed by the blanking"

# (4c) ⛔ THE PREVIOUS ROUND'S DECLARED RESIDUAL IS NOW CLOSED (P1, fresh review at `f3875382b204`).
# `The parser has "3 blocking defects in it".` is an ORDINARY LINE, so the blanking does not apply to it
# at all and its own stated count refuses. Up to `f3875382b` this row asserted `rc=0`, i.e. the suite
# ENFORCED the fail-open — a later fix would have had to change a test to close it. The residual that
# remains is table-row-only, and §BV(1) pins its recording side while (4)/(4b) pin the refusal side.
reset; printf 'The parser has "3 blocking defects in it".\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a quoted count on an ORDINARY line is a reported finding again (rc=$(rc_of), want 7) - the declared fail-open is CLOSED"
no_record; ck $? "  ...nothing recorded, so no signed clean is minted over it"
err_has '3 blocking defects'; ck $? "  ...and the count it refused over is printed"

# (5) ⛔ THE DIAGNOSIS: the refusal must NAME BOTH LINES it reconciled and must not claim a shape it
# never saw. `a verdict-shaped line ALSO reports a non-zero count` was asserted over EVERY
# counted-clean refusal, including the measured #4251 one where the count sat on a mutation-table row
# with no verdict word at all. This is the reopened issue's demand — `the parser could not reconcile a
# count with a verdict, which is the parser's problem to name, not the reviewer's fault to blame for`.
reset; printf 'Summary: I found two blocking defects:\n- one in the parser\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a live count on an ordinary line still refuses (rc=$(rc_of), want 7) - the direction is unchanged"
err_not_has "a verdict-shaped line ALSO reports"; ck $? "  ...and it no longer claims the count sat on a verdict-shaped line (that line carried no verdict word)"
err_has "The count sits on a DIFFERENT line"; ck $? "  ...it says the two are on different lines — the reconciliation it could not perform"
err_has "could not tell which field was authoritative"; ck $? "  ...naming its OWN limit instead of blaming the reviewer"
err_has 'verdict line it compared : CLEAN'; ck $? "  ...and printing the verdict line it compared against"
err_has 'line the count matched   : Summary: I found two blocking defects:'; ck $? "  ...and the exact line it matched, so both halves of the reconciliation are visible"
err_has 'phrase it read           : " two blocking defects"'; ck $? "  ...and the exact phrase (leading separator included, as the pre-fix log printed it)"
# ⛔ AND THE LAST LINE OF THE REFUSAL MUST NOT CONTRADICT THE SENTENCE TWO LINES ABOVE IT (P2, fresh
# review at `0dd5e5519`): `die` was UNCONDITIONAL and said `a self-contradicting CLEAN verdict` on
# BOTH arms, including this one, whose own `err` line says the reader `could not tell which field was
# authoritative` — so the most visible line of the case the reopen is about still blamed the reviewer
# for a contradiction it had just said it could not point at. §BV(3) cannot see this: its
# `err_has "self-contradicting"` is satisfied by the same shared `die`, so it passes in EITHER arm.
err_not_has "self-contradicting"; ck $? "  ...and the terminal refusal does NOT call this arm self-contradicting (it is unreconciled, not contradictory)"

# (6) THE TWO LIVENESS VOCABULARIES CANNOT DRIFT. `unquote` decides what survives blanking, and the
# `_cue` test decides what survives the articles arm; if one gains a word the other lacks, a quotation
# is live to one reader and dead to the other — the drift MEMORY.md records for VD_ISSUES, one grammar
# over. Both are derived from the SUT, so an edit to either alone is red.
_BV_UNQ_LINE="$(grep -n 'live = (win ~' "$SRC" | head -1 | cut -d: -f1)"
[ -n "$_BV_UNQ_LINE" ]; ck $? "the quotation reader's liveness line was located (line ${_BV_UNQ_LINE:-<none>})"
_BV_UNQ_VOC="$(awk 'index($0,"live = (win ~ /("){ p="live = (win ~ /("; s=substr($0,index($0,p)+length(p)); print substr(s,1,index(s,")")-1) }' "$SRC" | head -1)"
_BV_CUE_VOC="$(awk 'index($0,"_cue !~ /^[^.;:,!?()]*("){ p="_cue !~ /^[^.;:,!?()]*("; s=substr($0,index($0,p)+length(p)); print substr(s,1,index(s,")")-1) }' "$SRC" | head -1)"
[ -n "$_BV_UNQ_VOC" ] && [ -n "$_BV_CUE_VOC" ]; ck $? "both liveness vocabularies were extracted live from the script (quotation='${_BV_UNQ_VOC:-<none>}')"
[ "$_BV_UNQ_VOC" = "$_BV_CUE_VOC" ]; ck $? "  ...and they are IDENTICAL, so no word can be live to one reader and dead to the other (cue='${_BV_CUE_VOC:-<none>}')"
# ⛔ THE EXACT SET, NOT ITS TWO ENDS (P3, fresh review at `0dd5e5519`): the previous row was
# `case "$_BV_UNQ_VOC" in remain\|*\|left)`, whose `\|` are LITERAL — it only required the string to
# BEGIN `remain|` and END `|left`, so deleting `still|open|unresolved|unfixed|outstanding|reopened`
# from BOTH readers kept it green (measured: `remainXleft` → 0; the shortened set → 0). The vocabulary
# decides which quotations survive blanking, so a silent shrink re-grades reviews unseen.
[ "$_BV_UNQ_VOC" = 'remain|remains|still|open|unresolved|unfixed|outstanding|reopened|left' ]; ck $? "  ...and it is EXACTLY the expected cue set, so no word can be dropped from both readers at once (got '${_BV_UNQ_VOC}')"

# (7) ⛔ THE MEASURED FAIL-OPEN, PINNED (P1, fresh review at `f3875382b204`). This is the line the review
# ran against the head: blanking EVERY quotation turned a STATED non-zero count of blocking findings
# into no finding, so a transcript that refused before #4253 recorded a signed clean. The fix confines
# the blanking to a table row; this line is prose, so its count is read exactly as the pre-#4253 seam
# read it. ⚠️ NON-VACUITY: RED at `f3875382b204`, where the pre-fix classifier blanked every quotation
# (measured there: the span was replaced before the three arms, so this line reported nothing while its
# unquoted twin still refused) and GREEN here; §BV(8) is the mutant that re-opens it.
reset; printf 'I found "3 blocking defects" in the parser.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a QUOTED count on an ordinary prose line is still a finding (rc=$(rc_of), want 7) - the P1 fail-open"
no_record; ck $? "  ...nothing recorded, so no signed clean is minted over a stated blocker"
err_has '3 blocking defects'; ck $? "  ...and the count is printed, not blanked away"

# (7b) ⛔ THE GATE IS A ROW, NOT "THE LINE CONTAINS A PIPE" (P1, fresh review at `f3875382b204` — the
# review offered `index(line,"|")>0` as the cheap gate; that predicate also matches PROSE that merely
# contains a shell pipeline). `I found "3 blocking defects"` must refuse wherever it is written, so the
# stricter test is pinned here and (9) shows what the cheaper one would have cost.
reset; printf 'The suite runs `grep x | wc -l` and found "3 blocking defects" in the parser.\nCLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "7" ]; ck $? "a quoted count in prose that happens to contain a PIPE is still a finding (rc=$(rc_of), want 7)"

# (8) ⛔ MUTATION CONTROL FOR THE GATE ITSELF, IN THE FAIL-OPEN DIRECTION: delete the table-row test and
# every line is blanked again — the exact pre-fix behaviour. (7) goes RED and (1) stays GREEN, which is
# what shows the ROW TEST, not the removal of the blanking, is what closes the fail-open.
BV2="$TMP/mutant-blank-all.sh"
sed 's/^  if (substr(_t, 1, 1) != "|") return s$/  if (0) return s/' "$SRC" > "$BV2"
if cmp -s "$SRC" "$BV2"; then
  fail "the table-row-gate mutation did not apply - this control proves NOTHING"
else
  reset; printf 'I found "3 blocking defects" in the parser.\nCLEAN\n' > "$TMP/reviewer-out"
  run "$BV2" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT that blanks EVERY line records the same prose count (rc=$(rc_of), want 0) - so the table-row gate is what refuses it"
  reset; FIXTURE_NO_MUTATION=1
  cat > "$TMP/reviewer-out" <<'BVMEASURED'
## MUTATION ATTRIBUTION

| assertion | mutant (the edit that reverts the fix) | reddened row | observed |
|---|---|---|---|
| `scripts/activate-harness.test.sh:581` — "no shipped template is an unmapped declaration error" | drop `\|eldato-disk-reaper-cache` from `installer_for()` | T1 `:581` | author-measured pre-fix output carries `DECLARATION ERROR … must UNKNOWN`; UNVERIFIED here — `bash scripts/activate-harness.test.sh` |

CLEAN
BVMEASURED
  run "$BV2" 2284
  [ "$(rc_of)" = "0" ]; ck $? "  ...and the measured #4251 TABLE ROW still records under it, so the fix narrowed the blanking and did not remove it"
fi

# (9) ⛔ MUTATION CONTROL FOR THE STRICTER PREDICATE: widen the gate to "the line contains a pipe" (the
# cheap form the review proposed) and (7b)'s prose line is blanked → it records a signed clean over a
# stated blocker. That is why the gate is anchored to the START of the line.
BV3="$TMP/mutant-any-pipe.sh"
sed 's/^  if (substr(_t, 1, 1) != "|") return s$/  if (index(_t, "|") == 0) return s/' "$SRC" > "$BV3"
if cmp -s "$SRC" "$BV3"; then
  fail "the any-pipe-gate mutation did not apply - this control proves NOTHING"
else
  reset; printf 'The suite runs `grep x | wc -l` and found "3 blocking defects" in the parser.\nCLEAN\n' > "$TMP/reviewer-out"
  run "$BV3" 2284
  [ "$(rc_of)" = "0" ]; ck $? "the MUTANT with the cheap any-pipe gate RECORDS that prose count (rc=$(rc_of), want 0) - so anchoring the gate to the line start is load-bearing"
fi
rm -f "$BV" "$BV2" "$BV3"; reset
# ══ end §BV ══

# ── §BW A STALE HEAD IS NOT A STALE REVIEW (agent-infra#4255) ────────────────
# THE HARM. `review-pr.sh`'s only pre-review guard used to be "is a clean record bound to this exact
# sha?". A PR whose head moved for the one reason that never changes what was reviewed — the base
# advanced and the branch was refreshed onto it — answered NO and bought a 20-40 minute review.
# These scenarios drive the seam to the RECORDER's own predicate (`--check-carry`) instead, and
# assert the OBSERVABLES that matter: was a reviewer paid for, was a record minted, at which head.
echo; echo "§BW the recorder's carry predicate is asked BEFORE a review is bought"
REC_HEAD_OLD="2222222222222222222222222222222222222222"
# The PRECONDITION of every carry answer is a record that exists and names an EARLIER head, so the
# carry-patch scenarios seed the store with exactly that (a fresh `reset` empties it). Verdict `clean`
# and a real `evidence` field: `--check-carry` treats a `carried` record with no provenance as
# NO RECORD (#10177), so a sloppier fixture would not model the shape being carried.
seed_stale_record() {
  mkdir -p "$TMP/home/.pi/agent/reviews"
  printf '{"pr":2284,"head_sha":"%s","mint":"fresh","evidence":"comment:1234","verdict":"clean","repo":"%s","reviewed_at":"2026-11-01T00:00:00Z"}\n' \
    "$REC_HEAD_OLD" "$REPO_FIXTURE" > "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json"
}

# (1) `carry` — the reviewed DIFF is byte-identical, so the gate already carries the record.
reset; FIXTURE_CC_TOKEN=carry; FIXTURE_CC_RC=0
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "(1) carry: exit 0 — nothing is stale and nothing is owed (rc=$(rc_of))"
no_reviewer; ck $? "(1) carry: NO reviewer was spawned"
no_record; ck $? "(1) carry: no record was re-minted (the gate carries the existing one as-is)"
out_has "NO REVIEW OWED"; ck $? "(1) carry: the answer says so, naming the recorder's own predicate"
[ "$(cat "$TMP/check-carry-pr.txt" 2>/dev/null)" = "2284" ]; ck $? "(1) carry: it asked about THIS PR"

# (2) `carry-patch` (#1377) — the rendered diff moved, every reviewed line identical: RE-RECORD at the
# CURRENT head and buy no review. The positional sha must be the RECORDED one (a same-head call is a
# fresh mint that refuses a blank --evidence); the fixture re-binds to the live head exactly as the
# real recorder's carry arm does, which is what makes the "recorded at the LIVE head" assertion real.
reset; FIXTURE_CC_TOKEN=carry-patch; FIXTURE_CC_RC=6
FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD_FIXTURE"; seed_stale_record
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "(2) carry-patch: exit 0 (rc=$(rc_of))"
no_reviewer; ck $? "(2) carry-patch: NO reviewer was spawned — this is the 20-40 min the issue is about"
case "$(cat "$TMP/record-argv.txt" 2>/dev/null)" in
  "2284 $REC_HEAD_OLD "*) rc=0 ;;
  *) rc=1 ;;
esac
ck $rc "(2) carry-patch: re-recorded with the RECORDED head positionally, never the live one (got: $(cat "$TMP/record-argv.txt" 2>/dev/null))"
case "$(cat "$TMP/record-argv.txt" 2>/dev/null)" in
  *"--expect-head"*) rc=1 ;;
  *) rc=0 ;;
esac
ck $rc "(2) …and WITHOUT --expect-head, which the recorder refuses precisely when the head moved"
grep -q "\"head_sha\":\"$HEAD_FIXTURE\"" "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "(2) …and the record now COVERS the live head (what the gate reads)"
out_has "NO REVIEW OWED"; ck $? "(2) …and says the re-binding is mechanical, not a new verdict"

# (3) THE FAIL-SAFE DIRECTION: if the carry cannot be SHOWN (the recorder did not land a clean record
# at the live head), the seam must fall through to a real review. A short-circuit that trusted its own
# token would leave the PR unreviewed AND unrecorded — a wall, not a saving.
reset; FIXTURE_CC_TOKEN=carry-patch; FIXTURE_CC_RC=6; FIXTURE_RECORD_RC=1; seed_stale_record
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ -f "$TMP/pi-runs.txt" ]; ck $? "(3) an UNPROVEN carry falls through and the reviewer IS spawned (no silent wall)"
err_has "did NOT produce a clean record"; ck $? "(3) …naming the failed prerequisite instead of claiming a carry"

# (4) THE MEASURED PRODUCTION CASE: on this box the store has NO record for the PR, though the BODY
# carries a correctly-signed marker (#14746/#14774 answered `norecord` while their bodies carried
# one). The seam must rebuild the store record (`--recover-body`) and ASK AGAIN before paying.
reset; FIXTURE_CC_TOKEN=norecord; FIXTURE_CC_RC=4
FIXTURE_RECOVER_RC=0; FIXTURE_CC_TOKEN_AFTER_RECOVER=carry; FIXTURE_CC_RC_AFTER_RECOVER=0
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "(4) norecord: recovered from the signed body marker, then carried (rc=$(rc_of))"
[ -f "$TMP/recover-pr.txt" ]; ck $? "(4) …--recover-body WAS asked (a store-less box is not evidence of changed content)"
[ "$(wc -l < "$TMP/check-carry-pr.txt" 2>/dev/null | tr -d ' ')" = "2" ]; ck $? "(4) …and the question was asked a SECOND time after the recovery"
no_reviewer; ck $? "(4) …and no reviewer was spawned"

# (5)/(6) NOT A REVIEW, AND NOT A REFUSAL OF THE CODE: a failed READ is a RETRY, and a RED BUILD is
# not a review finding. Both must leave the money unspent and name the right remedy.
reset; FIXTURE_CC_TOKEN=unreadable; FIXTURE_CC_RC=3
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "12" ]; ck $? "(5) unreadable: exit 12 (RETRY), not a review (rc=$(rc_of))"
no_reviewer; ck $? "(5) …no reviewer spawned"
no_record; ck $? "(5) …nothing recorded"
err_has "failed READ"; ck $? "(5) …and the remedy says the read failed, never that the diff changed"
reset; FIXTURE_CC_TOKEN=red-surface; FIXTURE_CC_RC=7
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "13" ]; ck $? "(6) red-surface: exit 13, not a review (rc=$(rc_of))"
no_reviewer; ck $? "(6) …no reviewer spawned for a broken build"
no_record; ck $? "(6) …nothing recorded"

# (7) `head` — a clean-family record (e.g. `clean-low`) already bound to this head: refused as the
# unchanged-head case, NOT carried and NOT re-reviewed.
reset; FIXTURE_CC_TOKEN=head; FIXTURE_CC_RC=0
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "5" ]; ck $? "(7) head: exit 5 — nothing to review, nothing to re-record (rc=$(rc_of))"
no_reviewer; ck $? "(7) …no reviewer spawned"

# (8) NON-VACUITY, THE OTHER DIRECTION: a genuinely CHANGED artifact still buys a review. Without this
# the whole section could be satisfied by a seam that never reviews anything.
reset; FIXTURE_CC_TOKEN=fresh; FIXTURE_CC_RC=1
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "0" ]; ck $? "(8) fresh: the ordinary review still runs and records (rc=$(rc_of))"
[ -f "$TMP/pi-runs.txt" ]; ck $? "(8) …the reviewer WAS spawned (a changed diff is still reviewed)"
[ -f "$TMP/record-argv.txt" ]; ck $? "(8) …and the record is minted"

# (10) ⛔ THE RECORD STORE IS ONLY HALF THE ATTESTATION (P2, fresh review of #4256 at
# `a3ee7be7dfda`). The `carry-patch` arm re-records and exits 0 on `record_at_head_family`, which reads
# `$HOME/.pi/agent/reviews` — while check (c) and `ai-review-gate` read the SIGNED MARKER IN THE PR BODY.
# The recorder's evidence post is BEST-EFFORT and exits 0 when the body read or PATCH fails, so this
# scenario — record file present at the live head, NO marker appended — used to print "NO REVIEW OWED …
# the record was RE-RECORDED" and exit 0 while the gate stayed RED and no review existed. It is also
# self-locking: the next `--check-carry` reads the store, answers `head`, and the seam exits 5, so
# nothing ever re-posts the marker. The seam must instead name the missing half.
reset; FIXTURE_CC_TOKEN=carry-patch; FIXTURE_CC_RC=6
FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD_FIXTURE"; seed_stale_record; FIXTURE_MARKER_MISSING=1
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "(10) carry-patch with NO body marker: exit 9, never the 'NO REVIEW OWED' claim (rc=$(rc_of))"
no_reviewer; ck $? "(10) …no reviewer spawned (the record IS current — the BODY marker is the missing half, not the review)"
out_not_has "NO REVIEW OWED"; ck $? "(10) …and the success line is NOT printed over a store-only attestation"
err_has "PR BODY carries no marker"; ck $? "(10) …the refusal names the half that is missing (check (c) reads the body)"
grep -q "\"head_sha\":\"$HEAD_FIXTURE\"" "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "(10) …and the STORE really was re-recorded at the live head — so the arm cannot be satisfied by the re-record failing"
# …the second half of the same harm: rc=0 with an UNSIGNED marker (no key on the box) is a record the
# gate fails closed on, and this file already refuses that shape by name after a fresh record (:4009).
reset; FIXTURE_CC_TOKEN=carry-patch; FIXTURE_CC_RC=6
FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD_FIXTURE"; seed_stale_record; FIXTURE_NO_KEY=1
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "9" ]; ck $? "(10) carry-patch with an UNSIGNED body marker: exit 9 too (rc=$(rc_of))"
no_reviewer; ck $? "(10) …no reviewer spawned for an unsigned re-record either"
err_has "UNSIGNED"; ck $? "(10) …and the refusal names the missing signature rather than a missing marker"

# (10b) ⛔ A FAILED BODY READ AFTER THE RE-RECORD IS ITS OWN REFUSAL (P3, fresh review of PR #4257 at
# `c2e80bac1db7`). The carry arm's `gh pr view --json body` read has TWO failure modes and they need
# OPPOSITE remedies: rc=0 with no marker bound to this head (the re-record's best-effort post did not
# land — re-run the recorder) versus a NON-ZERO read (the API did not answer — the marker may be there
# and correct, so re-running the recorder is a no-op and a PAID review must not be bought). Without a
# scenario the fourth outcome was unasserted: replacing that arm with `*) : ;;` left this suite green,
# and the seam then fell through to a full review of a head that already carries a valid, diff-identical
# record — the exact money #4255 exists to stop spending.
reset; FIXTURE_CC_TOKEN=carry-patch; FIXTURE_CC_RC=6
FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD_FIXTURE"; seed_stale_record; FIXTURE_READ_FAIL=body
printf 'CLEAN\n' > "$TMP/reviewer-out"
run "$SRC" 2284
[ "$(rc_of)" = "12" ]; ck $? "(10b) a FAILED body read after the re-record => exit 12, a RETRY refusal (rc=$(rc_of))"
err_has "could not be READ"; ck $? "(10b) …naming the READ failure, not a missing marker (the two have opposite remedies)"
out_not_has "NO REVIEW OWED"; ck $? "(10b) …and never claiming the carry on a marker it could not read back"
no_reviewer; ck $? "(10b) …and no reviewer paid for a read failure"
grep -q "\"head_sha\":\"$HEAD_FIXTURE\"" "$TMP/home/.pi/agent/reviews/daniel-ospina-agent-infra-2284.json" 2>/dev/null
ck $? "(10b) …with the store re-record still landed — so the arm is the READ's doing, not a failed re-record"

# (11) MUTATION CONTROL for (10): weaken the marker gate to "the store landed" and the marker-less
# scenario exits 0 — so §BW(10) is the gate's doing, not the fixture's.
MUT_MARK="$TMP/mutant-nomarkergate.sh"
sed 's/^      . "\$CR_MARKER" = signed . && CR_MARKER_OK=1$/      CR_MARKER_OK=1/' "$SRC" > "$MUT_MARK"; chmod +x "$MUT_MARK"
if cmp -s "$SRC" "$MUT_MARK"; then
  fail "§BW(11) the mutation did not apply — the marker gate changed shape, so this control proves NOTHING"
else
  pass "§BW(11) mutation applied (the signed-marker gate made unconditional)"
  reset; FIXTURE_CC_TOKEN=carry-patch; FIXTURE_CC_RC=6
  FIXTURE_LIVE_HEAD_AT_RECORD="$HEAD_FIXTURE"; seed_stale_record; FIXTURE_MARKER_MISSING=1
  printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$MUT_MARK" 2284
  [ "$(rc_of)" = "0" ]; ck $? "§BW(11) the MUTANT ACCEPTS a store-only attestation (rc=$(rc_of), want 0) — so §BW(10)'s refusal is the gate's doing"
  out_has "NO REVIEW OWED"; ck $? "§BW(11) …and prints the false success line the gate exists to stop"
fi
rm -f "$MUT_MARK"; reset

# (9) MUTATION: disable the carry arm and the §BW(1) scenario pays for a review — so §BW(1) is the
# arm's doing and not the fixture's.
MUT_CC="$TMP/mutant-nocarry.sh"
# ⛔ THE REPLACEMENT MUST CONTAIN NO `|`: a `case` arm is a GLOB, so `|` is alternation, and the
# first draft renamed only the SECOND alternative — `carry|red-base-owned-DISABLED` still MATCHED
# `carry`, the mutant behaved like the real script, and the control silently proved nothing.
sed 's/^  carry|red-base-owned)$/  __never_a_token__)/' "$SRC" > "$MUT_CC"; chmod +x "$MUT_CC"
if cmp -s "$SRC" "$MUT_CC"; then
  fail "§BW(9) the mutation did not apply — the anchored carry arm changed shape, so this control proves NOTHING"
else
  pass "§BW(9) mutation applied (the carry arm made unmatchable)"
  reset; FIXTURE_CC_TOKEN=carry; FIXTURE_CC_RC=0
  printf 'CLEAN\n' > "$TMP/reviewer-out"
  run "$MUT_CC" 2284
  [ -f "$TMP/pi-runs.txt" ]; ck $? "§BW(9) the MUTANT BUYS A REVIEW on an unchanged artifact — so §BW(1) is the arm's doing"
fi
rm -f "$MUT_CC"; reset
# ══ end §BW ══

# ⛔ THE PIN MUST NOT COUNT WHAT THE BOX DECIDES (P1, MEASURED at 0dd5e5519 on PR #4253). The floor
# used to be an absolute total, and §AT drives six assertions per awk implementation the box happens to
# have — so the same suite, at the same head, printed a DIFFERENT total on a four-dialect box than on a
# three-dialect one. GitHub's ubuntu runner is a three-dialect box (awk→gawk, gawk, mawk; no nawk), so
# an absolute floor was a red NO CHANGE COULD CLEAR on CI — the opposite of a tripwire: a
# permanently-red assertion trains readers to ignore the pin and hides the section loss it exists for.
# The pin therefore holds the STABLE surface (what §AT's dialect loop drove is subtracted, and that
# loop's own size is pinned exactly above, at `6 × installed dialects`), so it means the same thing on
# every box, and a lost section still moves it.
# ⛔ THE ARITHMETIC, BECAUSE THE PREVIOUS VERSION OF THIS COMMENT DID NOT CLOSE IT (P3, fresh review at
# `f3875382b204`: it quoted "1275 on a four-dialect box / 1268 on this three-dialect box" against a pin
# of 1257 — and 1257 + 6×4 + 2 is 1283, not 1275, so at least one quoted total was not a same-head
# measurement). What a green run prints is EXACTLY
#
#     total = pin_value + (6 × installed awk dialects) + 2
#
# (six per dialect from §AT's loop, one for the §AT delta assertion, one for this pin's own `ck`). So
# re-measure by RUNNING the suite and reading its printed total:
#     pin_value = total − 6 × <the dialect count the run itself reported> − 2
# Never copy a total printed on another box into this file, and never copy a pin value from a comment.
# MEASURED at this head (the #4255 merge, §BW + its §BW(10)/(11) store-vs-body arm AND the
# §BW(10b) body-read refusal — P3, fresh review of PR #4257 round 2: the pin and this comment were
# left five short when §BW(10b) landed, and a pin that low is a tripwire that five deleted
# assertions walk through): 1332 printed on a three-dialect Linux box (awk→mawk, mawk, nawk; no
# gawk), i.e. 1312 outside the env-dependent loop; the four-dialect twin prints 1338 and wants the
# SAME 1312.
[ "$(( PASS - _AT_ENV_ASSERTIONS ))" -ge 1312 ]; ck $? "assertion-count pin: >= 1312 assertions outside the env-dependent §AT dialect loop (section loss tripwire)"
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
