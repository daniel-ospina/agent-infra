#!/usr/bin/env bash
# gh-rest.test.sh — offline checks for the gh REST adapter (#1959).
#
# No network, no credentials, no real GitHub: a STUB gh (via GH_REST_REAL_GH) emits canned REST
# payloads and records every invocation, so the assertions pin the adapter's TRANSLATION — the only
# part that can silently corrupt a dispatch or a merge decision.
#
# ⛔ THE INVOCATIONS BELOW ARE COPIED FROM THE CALLERS, not invented. The first draft of this suite
# asserted shapes nobody used and shipped two P0s green:
#   * `pr list --head` was dropped => chain-merge.sh polls "the branch's PR", receives the newest
#     open PR instead, and merges an UNRELATED PR;
#   * `pr comment` printed no URL => merge-one.sh cannot extract the evidence artifact and parks
#     every reviewed PR with a false diagnosis.
# Every case below therefore names the caller it protects.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHIM="$HERE/gh-rest/gh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ck() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL %s\n' "$1"; fi; }
[ -x "$SHIM" ] || { echo "shim is not executable: $SHIM" >&2; exit 1; }

# ── the stub "real" gh ────────────────────────────────────────────────────────────────────────────
cat >"$TMP/stub-gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
if [ "${STUB_ANY_FAIL:-0}" = 1 ]; then
  # EXACTLY what the layer prints when it gives up on a read: bucket + reset, on stderr.
  printf 'gh-limit: gh rate limit (bucket=core reset=1700003600) — FAILED after 4 attempts\n' >&2
  exit 1
fi
# §Z: a page LARGER THAN ARG_MAX. Served from a file so the fixture can be megabytes without
# travelling through this script's own argv (which would hit the very limit under test).
if [ -n "${STUB_CHECKRUNS_FILE:-}" ]; then
  case "$*" in *"check-runs"*) cat "$STUB_CHECKRUNS_FILE"; exit 0 ;; esac
fi
if [ -n "${STUB_COMMENTS_FILE:-}" ]; then
  case "$*" in *"/comments"*) cat "$STUB_COMMENTS_FILE"; exit 0 ;; esac
fi
# §Z(e): an UNPARSEABLE body with rc 0 — the "a failed read is not an empty surface" contract has to
# be reachable from the suite, and the only way to make the READ succeed while its BODY is garbage is
# to serve the garbage. (STUB_STS_FAIL fails the read in bash, which is a different path.)
if [ -n "${STUB_STATUSES_FILE:-}" ]; then
  case "$*" in *"/status") cat "$STUB_STATUSES_FILE"; exit 0 ;; esac
fi
case "$*" in *"/comments?per_page"*)
  if [ "${STUB_COMMENTS_FAIL:-0}" = 1 ]; then
    printf 'gh-limit: gh rate limit (bucket=core reset=1700003600) — FAILED after 4 attempts\n' >&2
    exit 1
  fi ;; esac
case "$*" in *"commits/"*"/status")
  if [ "${STUB_STS_FAIL:-0}" = 1 ]; then
    printf 'gh-limit: gh rate limit (bucket=core reset=1700003600) — FAILED after 4 attempts\n' >&2
    exit 1
  fi ;; esac
case "$*" in *"--jq .head.sha"*)
  if [ "${STUB_SHA_FAIL:-0}" = 1 ]; then
    # EXACTLY what the layer prints when it gives up: the bucket and the reset, on stderr.
    printf 'gh-limit: RATE LIMITED bucket=core reset=1700003600 attempts=4\n' >&2
    exit 1
  fi
  printf '%s' '75c0353907f016cf71661d8a6b11f61bf4d5092f'; exit 0 ;; esac
case "$*" in *"--auto"*) printf 'STUB: delegated auto-merge'; exit 0 ;; esac
# A DELEGATED `issue view` (PR-numbered target): real gh answers such a number with an OBJECT, and the
# adapter must pass that answer through untouched. Only the REST path below starts with `repos/`.
case "$*" in *"issue view 900 "*) printf '%s' '{"number":900,"title":"a pull request","state":"MERGED","stateReason":"","assignees":[],"url":"https://example/900"}'; exit 0 ;; esac
# POST /comments (pr comment) and GET /comments (pr view --json comments) share a path — split on method.
case "$*" in *"-X POST"*"/comments"*) printf '{"id":7,"html_url":"https://github.com/o/r/pull/8833#issuecomment-7"}'; exit 0 ;; esac
path="$(printf '%s\n' "$@" | grep -m1 -E '^repos/')"
case "$path" in
  *"/pulls/9001/merge"*)  printf '{"merged":false,"message":"Pull Request is not mergeable"}'; exit 0 ;;
  *"/merge"*)             printf '{"sha":"abc1234def","merged":true,"message":"Pull Request successfully merged"}'; exit 0 ;;
  *"ready_for_review"*)   printf '{}'; exit 0 ;;
  # check-runs BEFORE status: "check-runs" does not contain "/status", but order still matters.
  *"check-runs"*)         printf '%s\n%s\n' \
      '{"check_runs":[{"name":"ai-review-gate","status":"completed","conclusion":"success","started_at":"2026-10-23T01:00:00Z","completed_at":"2026-10-23T01:05:00Z","details_url":"https://x/runs/1","app":{"slug":"github-actions"}},{"name":"changes","status":"in_progress","conclusion":null,"started_at":"2026-10-23T01:06:00Z","details_url":"https://x/runs/2","app":{"slug":"github-actions"}}]}' \
      '{"check_runs":[{"name":"python-ci-gate","status":"completed","conclusion":"failure","started_at":"2026-10-23T01:10:00Z","completed_at":"2026-10-23T01:20:00Z","details_url":"https://x/runs/12345/job/9","app":{"slug":"github-actions"}}]}'
      exit 0 ;;
  *"/status")             # legacy commit status (StatusContext) — not a check run
      printf '{"statuses":[{"context":"vercel/deploy","state":"pending","target_url":"https://vercel/1","creator":{"login":"vercel"}}]}'; exit 0 ;;
  *"/pulls/8833")         printf '%s' '{"number":8833,"title":"fix","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"fix/thing","sha":"75c0353907f016cf71661d8a6b11f61bf4d5092f"},"base":{"ref":"main"},"html_url":"https://example/8833","comments":7}'; exit 0 ;;
  *"/pulls/8229")         printf '%s' '{"number":8229,"state":"open","merged_at":null,"mergeable":false,"mergeable_state":"dirty","draft":false,"head":{"ref":"x","sha":"deadbeef"}}'; exit 0 ;;
  *"/pulls?state="*)      printf '%s' '[{"number":9001,"title":"unrelated newest","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"other","sha":"o1"}},{"number":3,"title":"c","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"c","sha":"c3"}},{"number":2,"title":"b","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"b","sha":"b2"}}]'; exit 0 ;;
  *"/issues?state="*)     printf '%s' '[{"number":900,"title":"a pull request","state":"open","pull_request":{"url":"x"}},{"number":8491,"title":"real issue","state":"open","labels":[{"name":"P0-blocker"}]},{"number":8492,"title":"another","state":"open","labels":[]}]'; exit 0 ;;
  *"/issues/8833/comments"*|*"/comments?per_page"*) printf '%s\n%s\n' '[{"body":"LGTM","user":{"login":"rev"},"created_at":"2026-10-17"}]' '[{"body":"second","user":{"login":"rev2"},"created_at":"2026-10-18"}]'; exit 0 ;;
  *"/issues/900")        printf '%s' '{"number":900,"title":"a pull request","state":"open","state_reason":null,"assignees":[],"html_url":"https://example/900","pull_request":{"url":"x"}}'; exit 0 ;;
  *"/issues/9008"*)      printf '%s' '{"number":9008,"title":"dup","state":"closed","state_reason":"duplicate","assignees":[]}'; exit 0 ;;
  *"/issues/8491"*)       printf '%s' '{"number":8491,"title":"real issue","state":"open","labels":[{"name":"P0-blocker"}],"assignees":[{"login":"daniel-ospina"}]}'; exit 0 ;;
esac
echo "STUB: no fixture for: $*" >&2; exit 1
STUB
chmod +x "$TMP/stub-gh"
# GH_LIMIT_DIR keeps the LIMIT LAYER (#1988) hermetic too: without it the adapter's helper would
# write its lock, ETag cache and limit record into the operator's real ~/.cache/gh-limit.
run() { STUB_LOG="$TMP/log" GH_REST_REAL_GH="$TMP/stub-gh" GH_LIMIT_DIR="$TMP/limit" \
        GH_LIMIT_CONDITIONAL=0 bash "$SHIM" "$@"; }
stublog() { cat "$TMP/log" 2>/dev/null; }
json_eq() { python3 -c "import json,sys; d=json.load(sys.stdin); print(0 if $1 else 1)" 2>/dev/null || echo 1; }
# ⛔ No `producer | grep -q`: a quiet grep writes nothing into the pipe, so the PIPE (not the content)
# decides the test. Here-string instead — see scripts/check-no-sigpipe-grep.sh.
has() { grep -q -- "$1" <<<"$2"; }
haslog() { grep -q -- "$1" <<<"$(stublog)"; }

echo "gh-rest adapter (#1959) — assertions copied from real callers"

# ── A. pr view: REST vocabulary -> gh's ───────────────────────────────────────────────────────────
out="$(run pr view 8833 --repo o/r --json state,headRefOid 2>&1)"
ck "pr view maps open -> OPEN  (sweep: PR_ST)" \
   "$(printf '%s' "$out" | json_eq 'd["state"]=="OPEN"')"
ck "pr view maps head.sha -> headRefOid  (merge-one: HEAD)" \
   "$(printf '%s' "$out" | json_eq 'd["headRefOid"].startswith("75c0353")')"
# gh itself pretty-prints --json output, so line count is not the signal: exactly ONE JSON doc is.
ck "pr view prints exactly once (no fall-through to delegate)" \
   "$(printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(0 if isinstance(d,dict) and d.get("state")=="OPEN" else 1)' 2>/dev/null || echo 1)"
ck "mergeable true -> MERGEABLE" "$(run pr view 8833 --repo o/r --json mergeable 2>&1 | json_eq 'd["mergeable"]=="MERGEABLE"')"
ck "mergeable false -> CONFLICTING (REST mergeable_state=dirty)" \
   "$(run pr view 8229 --repo o/r --json mergeable 2>&1 | json_eq 'd["mergeable"]=="CONFLICTING"')"

# ── B. pr view WITHOUT --json delegates (plain rendering is not modelled)  — fix-one.sh:155 ───────
: >"$TMP/log"
out="$(run pr view 8833 --repo o/r --comments 2>&1)"
ck "pr view without --json DELEGATES (fix-one.sh:155 reads the raw comment dump)" \
   "$(haslog 'pr view 8833 --repo o/r --comments' && echo 0 || echo 1)"

# ── C. pr view --json comments returns an ARRAY (REST gives a count) ─────────────────────────────
out="$(run pr view 8833 --repo o/r --json comments 2>&1)"
ck "pr view --json comments is an array, not the REST count" \
   "$(printf '%s' "$out" | json_eq 'isinstance(d["comments"],list) and d["comments"][0]["body"]=="LGTM"')"

# ── D. pr checks: concatenated pages, state mapping, link, legacy statuses ───────────────────────
out="$(run pr checks 8833 --repo o/r --json name,state 2>&1)"
ck "pr checks merges CONCATENATED --paginate pages" \
   "$(printf '%s' "$out" | json_eq 'any(x["name"]=="ai-review-gate" for x in d)')"
ck "pr checks: completed -> conclusion (merge-one: gate==SUCCESS)" \
   "$(printf '%s' "$out" | json_eq 'any(x["name"]=="ai-review-gate" and x["state"]=="success" for x in d)')"
ck "pr checks: in-flight -> status" \
   "$(printf '%s' "$out" | json_eq 'any(x["name"]=="changes" and x["state"]=="in_progress" for x in d)')"
out="$(run pr checks 8833 --repo o/r --json name,link --jq '.[]|select(.name=="python-ci-gate")|.link' 2>&1)"
ck "pr checks --json name,link surfaces details_url (fix-one.sh:150 derives the run id)" \
   "$(has 'runs/12345' \"$out\" && echo 0 || echo 1)"
out="$(run pr checks 8833 --repo o/r --json name,state 2>&1)"
ck "pr checks includes LEGACY commit statuses (else a protection context is never green)" \
   "$(printf '%s' "$out" | json_eq 'any(x["name"]=="vercel/deploy" for x in d)')"

# ⛔ ORDERING FIELDS MUST SURVIVE THE PROJECTION, not just the allow-list. `startedAt` was in
# CHECK_FIELDS (so `gh pr checks --json ...,startedAt` passed the field check and was NOT delegated)
# while the projection emitted no such key — a caller ordering check runs by attempt got undefined
# on EVERY installed box, silently. MEASURED: the lander newest-attempt dedupe was inert through
# this adapter, so a re-run that came back green still read `1 FAILED check(s)`.
out="$(run pr checks 8833 --repo o/r --json name,state,startedAt,workflow 2>&1)"
ck "pr checks projects startedAt (a dedupe by newest attempt cannot work without it)" \
   "$(printf '%s' "$out" | json_eq 'all(("startedAt" in x) for x in d) and any(x.get("startedAt") for x in d)')"
ck "pr checks projects start times that can ORDER two attempts of one job (not all null)" \
   "$(printf '%s' "$out" | json_eq 'len({x.get("startedAt") for x in d if x.get("startedAt")}) >= 2')"
ck "pr checks still delegates a field it does not model (startedAt must not license a partial answer)" \
   "$(printf '%s' "$out" | json_eq 'all(("workflow" in x) for x in d)')"

# ── D2. pr checks WITHOUT --json delegates (the table is not modelled) ──────────────────────────
: >"$TMP/log"
out="$(run pr checks 8833 --repo o/r 2>&1)"
ck "pr checks without --json DELEGATES (table output is not modelled)" \
   "$(haslog 'pr checks 8833 --repo o/r' && echo 0 || echo 1)"

# ── D3. an UNMODELLED --json FIELD must delegate (the flag rule, applied to fields) ───────────────
# Measured AFTER shipping: collision_preflight.py asks for `closingIssuesReferences` — GraphQL-only,
# absent from REST. The adapter answered null, the pre-flight read that as "closes nothing", every
# candidate went INCOMPLETE and the backlog stayed 0 with capacity free: no lanes dispatched.
: >"$TMP/log"
run pr list --repo o/r --state open --json number,closingIssuesReferences >/dev/null 2>&1
ck "unservable --json field (closingIssuesReferences) DELEGATES instead of answering null" \
   "$(haslog 'closingIssuesReferences' && echo 0 || echo 1)"
: >"$TMP/log"
run pr list --repo o/r --state open --json number >/dev/null 2>&1
ck "a servable --json field still uses REST (no needless delegation)" \
   "$(haslog 'pulls?state=' && echo 0 || echo 1)"

# ── D4. `stateReason` is SERVED (the drained-backlog P0, measured 2026-10-18) ─────────────────────
# The collision pre-flight makes ONE gh-backed issue read —
# `gh issue view … --json number,title,state,stateReason,assignees,url` — and computes BOTH the
# `issue assignee/holder` surface and its `issue landed` decision from that one payload (a failed
# read marks the landed surface `issue-metadata-unavailable` beside it). Left off the allow-list the
# read DELEGATES to GraphQL: a needless draw on the scarce bucket, and on a refusal the tool recovers
# only through its own REST fallback for the refusal TEXTS it classifies as budget exhaustion (#1968)
# — any other refusal leaves the surface INCOMPLETE, which is enough to make every candidate's verdict
# unusable, so the refresh aborts by design (#1736) and `candidates.txt` stays at 0 against 200+ open
# issues. REST's issue object carries `state_reason`, so this is a SOURCE mapping, not a
# re-derivation — and `gh pr view --json stateReason` is invalid, so it must stay PR-rejected.
: >"$TMP/log"
out="$(run issue view 8491 --repo o/r --json number,state,stateReason,assignees,url 2>&1)"
ck "issue view --json stateReason is SERVED over REST (no GraphQL dependency for the pre-flight)" \
   "$(haslog 'repos/o/r/issues/8491' && ! haslog 'issue view 8491' && echo 0 || echo 1)"
ck "issue view serves stateReason as '' when REST has null (gh's own rendering)" \
   "$(printf '%s' "$out" | json_eq 'd["stateReason"]=="" and d["state"]=="OPEN"')"
: >"$TMP/log"
out="$(run issue view 9008 --repo o/r --json number,stateReason 2>&1)"
ck "issue view uppercases REST state_reason ('duplicate' -> 'DUPLICATE'), the value gh reports" \
   "$(printf '%s' "$out" | json_eq 'd["stateReason"]=="DUPLICATE"')"
ck "issue view state_reason read stays on REST (no delegation for a CLOSED issue either)" \
   "$(haslog 'repos/o/r/issues/9008' && ! haslog '9008 --repo o/r' && echo 0 || echo 1)"
# ⛔ PER-KIND, NOT GLOBAL: `gh pr view --json stateReason` is INVALID (gh 2.97.0: "Unknown JSON field:
# \"stateReason\""), so a PR consumer must still get gh's own refusal rather than a REST-invented key.
: >"$TMP/log"
run pr view 8833 --repo o/r --json stateReason >/dev/null 2>&1
ck "pr view --json stateReason still DELEGATES (gh rejects the field for PRs; REST must not invent it)" \
   "$(haslog 'pr view 8833 --repo o/r --json stateReason' && echo 0 || echo 1)"

# ── D5. `issue view` of a PR-NUMBERED target must DELEGATE, never answer `[]` ────────────────
# Issues and pull requests SHARE one number sequence, so `gh issue view <n>` on a PR number is a
# legitimate question — and it is the exact read `collision_preflight.py` makes for `issue landed`
# AND `issue assignee/holder` (#2645 in daniel-ospina/agent-infra is such a number). Measured
# 2026-10-24: the adapter applied its LIST-only "drop pull_request rows" filter on the VIEW path,
# printed `[]` with rc 0, and a fail-closed caller refused non-object JSON on BOTH surfaces. The
# candidate became INCOMPLETE, and six INCOMPLETE candidates are `ABORT: … judged NOTHING` — an
# empty dispatch backlog with capacity free, produced by the adapter (the class its own header calls
# "does not degrade the fleet, it disables it").
: >"$TMP/log"
out="$(run issue view 900 --repo o/r --json number,title,state,stateReason,assignees,url 2>&1)"
ck "issue view of a PR-numbered target DELEGATES (an empty [] is non-object JSON to the pre-flight)" \
   "$(haslog 'issue view 900 --repo o/r' && echo 0 || echo 1)"
ck "issue view of a PR-numbered target never prints the LIST shape ([])" \
   "$([ "$out" != "[]" ] && [ -n "$out" ] && echo 0 || echo 1)"
ck "issue view of a PR-numbered target returns a JSON OBJECT, the shape the caller was promised" \
   "$(printf '%s' "$out" | json_eq 'isinstance(d, dict) and d.get("number")==900')"
# NON-VACUITY for the same arm: a REAL issue number must still be served over REST, not delegated —
# otherwise "delegate on a PR" could hide a resolver that delegates everything (a silent GraphQL draw
# on the scarce bucket, which is the reason this arm exists at all).
: >"$TMP/log"
run issue view 8491 --repo o/r --json number,state >/dev/null 2>&1
ck "an ordinary issue read still stays on REST (the PR arm did not license delegating everything)" \
   "$(haslog 'repos/o/r/issues/8491' && ! haslog 'issue view 8491' && echo 0 || echo 1)"

# ── E. pr list --head must reach the API (chain-merge.sh:44 — else the WRONG PR is merged) ───────
: >"$TMP/log"
run pr list --repo o/r --state open --head BR --json number --jq '.[0].number' >/dev/null 2>&1
ck "pr list --head reaches the API as head=OWNER:BRANCH (P0: else an unrelated PR is merged)" \
   "$(haslog 'head=o:BR' && echo 0 || echo 1)"

# ── F. issue list --label must reach the API (refresh-candidates.sh severity tiers) ─────────────
: >"$TMP/log"
run issue list --repo o/r --state open --limit 300 --label P0-blocker --json number >/dev/null 2>&1
ck "issue list --label reaches the API as labels= (else P0/P1/P2 ordering inverts)" \
   "$(haslog 'labels=P0-blocker' && echo 0 || echo 1)"

# ── G. an UNMODELLED flag delegates instead of being dropped (the root-cause rule) ──────────────
: >"$TMP/log"
out="$(run pr list --repo o/r --search 'flaky' --json number 2>&1)"
ck "unmodelled flag (--search) DELEGATES rather than serving an unfiltered answer" \
   "$(haslog '--search' && echo 0 || echo 1)"

# ── H. limits / filtering ────────────────────────────────────────────────────────────────────────
ck "pr list honours --limit" "$(run pr list --repo o/r --limit 2 --json number 2>&1 | json_eq 'len(d)==2')"
ck "issue list EXCLUDES pull requests" \
   "$(run issue list --repo o/r --json number 2>&1 | json_eq '[x["number"] for x in d]==[8491,8492]')"
ck "issue view maps state" "$(run issue view 8491 --repo o/r --json number,state 2>&1 | json_eq 'd["state"]=="OPEN"')"

# ── I. pr comment MUST print the URL (merge-one.sh:452-483 parks on a missing evidence artifact) ──
printf 'review body\n' >"$TMP/rev.md"
out="$(run pr comment 8833 --repo o/r --body-file "$TMP/rev.md" 2>&1)"
ck "pr comment PRINTS the comment URL (P0: else every reviewed PR parks)" \
   "$(has 'issuecomment-7' \"$out\" && echo 0 || echo 1)"

# ── J. mutating calls ────────────────────────────────────────────────────────────────────────────
: >"$TMP/log"
run pr merge 8833 --repo o/r --squash --match-head-commit 75c0353 >/dev/null 2>&1
ck "pr merge --squash -> PUT merge_method=squash" "$(haslog 'merge_method=squash' && echo 0 || echo 1)"
# ⛔ THE POST-MERGE STEPS MUST NOT DECIDE THE EXIT CODE. The layer helper is `exec`'d, so a bare
# `[ … ] && run_real … || true` replaced the shim with the DELETE and returned ITS status: a
# SUCCESSFUL merge (this stub's DELETE always fails, as the real one does — the ref path is a
# pre-existing bug) came back rc≠0 and the caller read a landed merge as a failure.
run pr merge 8833 --repo o/r --squash --delete-branch >/dev/null 2>&1; rc=$?
ck "pr merge --delete-branch still reports SUCCESS (the branch delete cannot fail the merge)" \
   "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
ck "pr merge --delete-branch does attempt the delete" "$(haslog 'git/refs/heads' && echo 0 || echo 1)"
ck "pr merge passes --match-head-commit as sha" "$(haslog 'sha=75c0353' && echo 0 || echo 1)"
: >"$TMP/log"
run pr merge 9001 --repo o/r --squash >/dev/null 2>&1; rc=$?
ck "pr merge with body merged:false FAILS (a 200 is not a merge)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
: >"$TMP/log"
run pr merge 8833 --repo o/r --auto >/dev/null 2>&1
ck "pr merge --auto delegates (GraphQL-only mutation)" "$(haslog '--auto' && echo 0 || echo 1)"
ck "pr merge --auto issues NO merge PUT" "$(stublog | grep -q '/merge' && echo 1 || echo 0)"
: >"$TMP/log"
run pr merge 8833 --repo o/r >/dev/null 2>&1
ck "pr merge with NO method delegates (gh derives it from repo settings)" \
   "$(haslog 'pr merge 8833' && echo 0 || echo 1)"
: >"$TMP/log"
# ⛔ THE OUTPUT IS THE ASSERTION, NOT THE EXIT CODE: with `exec` in `run_real`, a bare form replaced
# the shim with the POST, so the confirmation line was lost while rc stayed 0 in BOTH shapes —
# asserting only rc passed on the reverted code (found in review round 4).
out="$(run pr ready 8833 --repo o/r 2>&1)"; rc=$?
ck "pr ready -> REST ready_for_review" "$(haslog 'ready_for_review' && echo 0 || echo 1)"
ck "pr ready still prints its confirmation after an exec'd request" \
   "$([ "$rc" -eq 0 ] && has 'marked as "ready for review"' "$out" && echo 0 || echo 1)"

# ── K. failures stay loud ────────────────────────────────────────────────────────────────────────
ck "a failing --jq exits NON-ZERO (empty+0 is indistinguishable from 'no rows')" \
   "$(run pr view 8833 --repo o/r --json number --jq '.number[]' >/dev/null 2>&1; [ $? -ne 0 ] && echo 0 || echo 1)"
: >"$TMP/log"
run api repos/o/r --jq .name >/dev/null 2>&1
ck "untranslated command delegates verbatim (gh api is already REST)" \
   "$(haslog 'api repos/o/r' && echo 0 || echo 1)"

# ── Z. A REFUSED READ MUST NOT LOOK LIKE AN EMPTY SURFACE ────────────────────────────────────────
# The head-sha read threw stderr away (`2>/dev/null`), so a layer refusal became "empty response" and
# the caller — which reads stdout only — turned it into NOCHECKS: a PR skipped silently every cycle on
# a box that was merely limited. The refusal's own words must reach the caller (review round 9).
# `GH_LIMIT_NO_WAIT=1` = what every bounded harness caller sets: the layer records the refusal and
# returns at once instead of sleeping 60 s (this suite has no fake clock).
out="$(GH_LIMIT_NO_WAIT=1 STUB_SHA_FAIL=1 run pr checks 8833 --repo o/r --json name,state 2>"$TMP/err-z")"; rc=$?
err="$(cat "$TMP/err-z")"
ck "pr checks on a REFUSED head-sha read names the refusal (bucket + reset) on stderr" \
   "$([ "$rc" -ne 0 ] && has 'RATE LIMITED bucket=core reset=1700003600' "$err" && echo 0 || echo 1)"
ck "pr checks on a REFUSED read prints NO surface on stdout (never a partial check set)" \
   "$([ -z "$out" ] && echo 0 || echo 1)"

# ── Y. EVERY READ KEEPS THE LAYER'S WORDS ────────────────────────────────────────────────────────
# `run_real … 2>&1 | jq` fed the refusal to jq: jq failed, its stdout was empty, and `die "$var"`
# printed a BLANK `gh-rest: ` with the bucket/reset nowhere — on four of the five reads (review
# round 10). Each must now name the bucket, and none may print a surface.
for _sub in "pr list --repo o/r --json number,title" \
            "issue list --repo o/r --json number,title" \
            "pr view 8833 --repo o/r --json state,comments" \
            "pr checks 8833 --repo o/r --json name,state"; do
  _o="$(GH_LIMIT_NO_WAIT=1 STUB_ANY_FAIL=1 run $_sub 2>"$TMP/err-y")"; _r=$?
  if [ "$_r" -ne 0 ] && has 'bucket=core reset=1700003600' "$(cat "$TMP/err-y")" && [ -z "$_o" ]; then
    pass=$((pass+1)); printf '  ok   refused %s: names the bucket and prints no surface\n' "$_sub"
  else
    fail=$((fail+1)); printf '  FAIL refused %s: rc=%s stdout=[%s] stderr=[%s]\n' \
      "$_sub" "$_r" "$_o" "$(cat "$TMP/err-y")"
  fi
done

# The COMMENTS read is the one `read_json` site whose sibling base read succeeds, so it is the only
# way to exercise that half of the fix directly.
_o="$(GH_LIMIT_NO_WAIT=1 STUB_COMMENTS_FAIL=1 run pr view 8833 --repo o/r --json state,comments 2>"$TMP/err-c")"; _r=$?
ck "a refused COMMENTS read names the bucket (not a bare jq parse error)" \
   "$([ "$_r" -ne 0 ] && has 'bucket=core reset=1700003600' "$(cat "$TMP/err-c")" \
      && ! has 'jq: parse error' "$(cat "$TMP/err-c")" && echo 0 || echo 1)"

# ── X. A REFUSED LEGACY-STATUS READ IS AN INCOMPLETE SURFACE, NOT "no legacy contexts" ────────────
# It used to return rc 0 with every StatusContext silently missing (a required context then read
# PENDING forever) and a message every caller discards.
_o="$(GH_LIMIT_NO_WAIT=1 STUB_STS_FAIL=1 run pr checks 8833 --repo o/r --json name,state 2>"$TMP/err-x")"; _r=$?
ck "a refused legacy commit-status read FAILS the call (rc!=0) and says the set is incomplete" \
   "$([ "$_r" -ne 0 ] && has 'INCOMPLETE' "$(cat "$TMP/err-x")" && [ -z "$_o" ] && echo 0 || echo 1)"

# ── Z. A PAYLOAD BIGGER THAN THE KERNEL'S LIMIT STILL PROJECTS (it used to be refused by exec) ────
# ⛔ THE DEFECT THIS PINS IS A FAILED READ THAT LOOKED LIKE "NO WORK". The projections handed the
# WHOLE check-runs / statuses / comments payload to python through argv and the environment
# (`R="$runs" S="$sts" python3 -c …`, `python3 -c … "$cs"`), which the kernel bounds by ARG_MAX.
# A BUSY PR exceeds it, the exec is refused with `Argument list too long`, the projection prints
# nothing — and the caller reads EMPTY STDOUT as an empty check surface. MEASURED on the cells
# (2026-10-25): `PR path: NO UNIT SPAWNED this cycle — 6 check surface READ-FAILED:other:
# …/gh-rest/gh: line 420: python3: Argument list too long`. So a payload over the limit must still
# produce the CORRECT check set — not merely "not crash".
#
# The fixture is sized from the box's OWN limits (min(ARG_MAX, 2 MiB), per the reproduction the
# issue prescribes) and the arm asserts the fixture REALLY exceeds it, so a machine with a huge
# ARG_MAX cannot silently turn this into a vacuous pass.
_argmax="$(getconf ARG_MAX 2>/dev/null || true)"
case "${_argmax:-}" in ''|*[!0-9]*) _argmax=1048576 ;; esac
# ⛔ SIZE FROM THE KERNEL LIMIT AND COMPARE LIKE WITH LIKE. An earlier version capped `_argmax` at
# 2 MiB and then sized the fixture at 2 × that cap — so the "cannot be vacuous" assertion compared the
# fixture against the SAME capped number it was derived from, which is ALWAYS true and is a false
# assurance on any box whose limit is bigger. The fixture is 2 × the kernel's own ARG_MAX and it is
# asserted against the kernel's own ARG_MAX (2 × ARG_MAX >= min(ARG_MAX, 2 MiB) on every box).
_big_n=$(( _argmax * 2 ))
python3 - "$TMP/big-runs.json" "$TMP/big-comments.json" "$_big_n" <<'PY'
import json, sys
runs_path, comments_path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
pad = "x" * n          # a field the projection does NOT emit, so the fixture is big and the
                        # answer it must produce is exactly the small, known check set below.
runs = {"check_runs": [
    {"name": "ai-review-gate", "status": "completed", "conclusion": "success",
     "started_at": "2026-10-23T01:00:00Z", "completed_at": "2026-10-23T01:05:00Z",
     "details_url": "https://x/runs/1", "app": {"slug": "github-actions"},
     "output": {"summary": pad}},
    {"name": "changes", "status": "in_progress", "conclusion": None,
     "started_at": "2026-10-23T01:06:00Z", "details_url": "https://x/runs/2",
     "app": {"slug": "github-actions"}, "output": {"summary": pad}},
]}
open(runs_path, "w").write(json.dumps(runs) + "\n")
open(comments_path, "w").write(json.dumps([
    {"body": pad, "user": {"login": "rev"}, "created_at": "2026-10-17"},
    {"body": "second", "user": {"login": "rev2"}, "created_at": "2026-10-18"},
]) + "\n")
PY
_big_sz="$(wc -c <"$TMP/big-runs.json" | tr -d '[:space:]')"
ck "§Z fixture really exceeds the KERNEL limit (${_big_sz}B > ARG_MAX ${_argmax}B) — the arm cannot be vacuous" \
   "$([ "${_big_sz:-0}" -gt "$_argmax" ] && echo 0 || echo 1)"
out="$(STUB_CHECKRUNS_FILE="$TMP/big-runs.json" run pr checks 8833 --repo o/r --json name,state 2>&1)"; rc=$?
# The check set must be CORRECT, not merely non-empty: the two runs from page 1 AND the legacy
# StatusContext (a separate read, which unions into the same surface) prove both payloads arrived.
# `json_eq` prints 0/1 on stdout, so a pipeline into it decides the arm by CONTENT.
_set_ok="$(printf '%s' "$out" | json_eq 'any(x["name"]=="ai-review-gate" and x["state"]=="success" for x in d) and any(x["name"]=="changes" and x["state"]=="in_progress" for x in d) and any(x["name"]=="vercel/deploy" for x in d)')"
[ "${_set_ok:-1}" = "0" ] && _set_rc=0 || _set_rc=1
ck "§Z a check-runs payload over ARG_MAX still projects, and the check set is CORRECT" \
   "$([ "$rc" -eq 0 ] && [ "$_set_rc" -eq 0 ] && echo 0 || echo 1)"
[ "$rc" -eq 0 ] && [ "$_set_rc" -eq 0 ] \
  || printf '       rc=%s set=%s stdout=[%.300s]\n' "$rc" "${_set_ok:-?}" "$out"
# ⛔ THE EXACT FAILURE IS WHAT IS FORBIDDEN. The defect's whole signature is the KERNEL's refusal
# arriving as empty stdout; assert the words are absent from BOTH streams, so a future change that
# reintroduces argv/env passing fails here even if it happens to answer correctly on a bigger box.
ck "§Z …with NO 'Argument list too long' on stdout or stderr" \
   "$(! has 'Argument list too long' "$out" && ! has 'E2BIG' "$out" && echo 0 || echo 1)"

# The COMMENTS payload is the second argv site: a long thread on a busy PR is megabytes too.
out="$(STUB_COMMENTS_FILE="$TMP/big-comments.json" run pr view 8833 --repo o/r --json state,comments 2>&1)"; rc=$?
_comm_ok="$(printf '%s' "$out" | json_eq 'isinstance(d.get("comments"),list) and len(d["comments"])==2 and len(d["comments"][0]["body"])>1000000 and d["comments"][1]["body"]=="second"')"
[ "${_comm_ok:-1}" = "0" ] && _comm_rc=0 || _comm_rc=1
ck "§Z a >ARG_MAX COMMENTS payload survives intact (both comments, the big body untruncated)" \
   "$([ "$rc" -eq 0 ] && [ "$_comm_rc" -eq 0 ] && echo 0 || echo 1)"
ck "§Z …and that path reports no 'Argument list too long' either" \
   "$(! has 'Argument list too long' "$out" && echo 0 || echo 1)"

# ⛔ AN UNPARSEABLE BODY WITH rc 0 IS A FAILED READ, NOT AN EMPTY CHECK SET — and without an arm this
# guarantee rots: reverting it to the old `except Exception: return []` left every assertion green
# (measured). The read SUCCEEDS here (the stub exits 0) and only the document is garbage, which is the
# one path that used to answer `[]` with rc 0 — a check surface that reads "no checks".
printf '<html>oops</html>\n' >"$TMP/bad-sts.json"
out="$(STUB_STATUSES_FILE="$TMP/bad-sts.json" run pr checks 8833 --repo o/r --json name,state 2>"$TMP/err-p")"; rc=$?
ck "§Z an UNPARSEABLE check payload FAILS the read (rc!=0, no surface) and names the key" \
   "$([ "$rc" -ne 0 ] && [ -z "$out" ] && has 'cannot parse the statuses payload' "$(cat "$TMP/err-p")" && echo 0 || echo 1)"
# …while an EMPTY body with rc 0 stays benign: that is "no rows", not a refused read, so the surface
# must still be produced from the check runs alone.
printf '' >"$TMP/empty-sts.json"
out="$(STUB_STATUSES_FILE="$TMP/empty-sts.json" run pr checks 8833 --repo o/r --json name,state 2>&1)"; rc=$?
_empt_ok="$(printf '%s' "$out" | json_eq 'any(x["name"]=="ai-review-gate" for x in d)')"
ck "§Z an EMPTY status body (rc 0) still yields the check set — it is 'no rows', not a failed read" \
   "$([ "$rc" -eq 0 ] && [ "${_empt_ok:-1}" = 0 ] && echo 0 || echo 1)"

# ⛔ NON-VACUITY, PINNED IN THE SUITE RATHER THAN ONLY IN THE PR TEXT: no projection site may pass
# its payload through the environment or argv. The env form is the one the kernel refused; the
# comments form put it in argv. A grep is enough here because the SHAPE is the defect and the arms
# above already prove the behaviour (reverting to either form fails them: measured on the pre-fix
# shim, the check-runs arm dies rc=1 with `Argument list too long` and prints the kernel message
# instead of a check set).
# The patterns name the SHAPE, not the two exact lines that were removed: any payload read out of the
# environment (`os.environ`, `os.getenv`), and any of the three payload variables handed to python as
# a value. (`[$]` rather than `\$`: a `\$` inside nested quotes is consumed by the OUTER double
# quotes and silently produced a zero-match pattern here once.)
_env_sites="$(grep -vE '^[[:space:]]*#' "$SHIM" | grep -cE 'os[.](environ|getenv)' || true)"
ck "§Z no projection reads its payload from the process ENVIRONMENT" \
   "$([ "${_env_sites:-0}" -eq 0 ] && echo 0 || echo 1)"
_argv_sites="$(grep -vE '^[[:space:]]*#' "$SHIM" | grep -cE 'python3.*"[$](cs|runs|sts)"' || true)"
ck "§Z no projection hands a payload VARIABLE to python as a value" \
   "$([ "${_argv_sites:-0}" -eq 0 ] && echo 0 || echo 1)"

echo
printf 'gh-rest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
