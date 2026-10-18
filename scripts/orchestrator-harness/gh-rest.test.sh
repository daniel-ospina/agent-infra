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
# POST /comments (pr comment) and GET /comments (pr view --json comments) share a path — split on method.
case "$*" in *"-X POST"*"/comments"*) printf '{"id":7,"html_url":"https://github.com/o/r/pull/8833#issuecomment-7"}'; exit 0 ;; esac
path="$(printf '%s\n' "$@" | grep -m1 -E '^repos/')"
case "$path" in
  *"/pulls/9001/merge"*)  printf '{"merged":false,"message":"Pull Request is not mergeable"}'; exit 0 ;;
  *"/merge"*)             printf '{"sha":"abc1234def","merged":true,"message":"Pull Request successfully merged"}'; exit 0 ;;
  *"ready_for_review"*)   printf '{}'; exit 0 ;;
  # check-runs BEFORE status: "check-runs" does not contain "/status", but order still matters.
  *"check-runs"*)         printf '%s\n%s\n' \
      '{"check_runs":[{"name":"ai-review-gate","status":"completed","conclusion":"success","details_url":"https://x/runs/1","app":{"slug":"github-actions"}},{"name":"changes","status":"in_progress","conclusion":null,"details_url":"https://x/runs/2","app":{"slug":"github-actions"}}]}' \
      '{"check_runs":[{"name":"python-ci-gate","status":"completed","conclusion":"failure","details_url":"https://x/runs/12345/job/9","app":{"slug":"github-actions"}}]}'
      exit 0 ;;
  *"/status")             # legacy commit status (StatusContext) — not a check run
      printf '{"statuses":[{"context":"vercel/deploy","state":"pending","target_url":"https://vercel/1","creator":{"login":"vercel"}}]}'; exit 0 ;;
  *"/pulls/8833")         printf '%s' '{"number":8833,"title":"fix","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"fix/thing","sha":"75c0353907f016cf71661d8a6b11f61bf4d5092f"},"base":{"ref":"main"},"html_url":"https://example/8833","comments":7}'; exit 0 ;;
  *"/pulls/8229")         printf '%s' '{"number":8229,"state":"open","merged_at":null,"mergeable":false,"mergeable_state":"dirty","draft":false,"head":{"ref":"x","sha":"deadbeef"}}'; exit 0 ;;
  *"/pulls?state="*)      printf '%s' '[{"number":9001,"title":"unrelated newest","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"other","sha":"o1"}},{"number":3,"title":"c","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"c","sha":"c3"}},{"number":2,"title":"b","state":"open","merged_at":null,"mergeable":true,"mergeable_state":"clean","draft":false,"head":{"ref":"b","sha":"b2"}}]'; exit 0 ;;
  *"/issues?state="*)     printf '%s' '[{"number":900,"title":"a pull request","state":"open","pull_request":{"url":"x"}},{"number":8491,"title":"real issue","state":"open","labels":[{"name":"P0-blocker"}]},{"number":8492,"title":"another","state":"open","labels":[]}]'; exit 0 ;;
  *"/issues/8833/comments"*|*"/comments?per_page"*) printf '%s\n%s\n' '[{"body":"LGTM","user":{"login":"rev"},"created_at":"2026-10-17"}]' '[{"body":"second","user":{"login":"rev2"},"created_at":"2026-10-18"}]'; exit 0 ;;
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

echo
printf 'gh-rest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
