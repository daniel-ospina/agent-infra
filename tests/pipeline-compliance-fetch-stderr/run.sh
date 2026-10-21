#!/usr/bin/env bash
# tests/pipeline-compliance-fetch-stderr/run.sh — a tooling failure is not a policy verdict,
# and a RATE LIMIT is not an access defect.
#
# WHY. Measured 2026-10-21 on agent-infra: pipeline-compliance was RED on seven of nine
# finished PRs (#1863 #2025 #2172 #1858 #1881 #1553 #1913) while ~20 other checks were
# green on the same sha, and it flipped green/red on the SAME code between runs. The
# message was jq's parse error on a non-JSON body:
#
#   ❌ [fetch] gh api failed for repos/.../pulls/1863 (exit 1):
#      invalid character 'S' looking for beginning of value
#
# printed as the whole story — on CI indistinguishable from a PR violating policy.
#
# TWO REVIEW ROUNDS SHAPED THIS SUITE.
#   1st: the fixture merged stderr into stdout and claimed that reproduced the message.
#        It did not — jq runs INSIDE `gh api --jq` on the HTTP BODY, so a non-JSON body,
#        not stderr, produces the parse error. The assertion was vacuous and was removed.
#   2nd: the classification put 403 in the PERMANENT class — but GitHub answers a RATE
#        LIMIT with 403 as well as 429, so the dominant transient in CI got the exact
#        inverse advice. Order is now pinned by a test: transient signatures are matched
#        FIRST, then parse failures, then 404/403 as an access defect.
#
# What is asserted:
#   1. a non-JSON body => BLOCKED-BY-TOOLING naming the parse failure, never a policy verdict
#   2. a 403 rate limit => TRANSIENT advice (re-run), NOT "access defect"
#   3. a plain 404 => reference/access advice (permanent)
#   4. success WITH a warning on stderr => the warning is surfaced, never consumed as data
#   5. every unreadable case fails CLOSED with exit 2
#   6. MUTATION: restore the old single-message shape => assertion 1 must FAIL
#
# Hermetic: a fake `gh` serves every call; no network, no auth, no real PR.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-pipeline-compliance.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pc-fetch-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checks=0
failures=0
ok()  { checks=$((checks + 1)); printf '  PASS %s\n' "$1"; }
bad() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# ── fake gh. Mirrors the real contract that matters: `--jq <expr>` runs jq over the
# RESPONSE BODY, so a non-JSON body makes gh itself fail with jq's message.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
mode="${FAKE_GH_MODE:-ok}"
case "$mode" in
  ok)
    body='{"body":"Refs #1012","labels":[],"user":{"login":"lane"},"merged":false,"state":"open","changed_files":2,"head":{"ref":"x"},"title":"t","number":1863,"base":{"ref":"main","repo":{"full_name":"daniel-ospina/agent-infra"}},"files":[],"commits":[]}'
    printf 'Warning: API rate limit is near its secondary threshold; continuing\n' >&2
    ;;
  nonjson)   # a 502/proxy page instead of JSON — what the seven red PRs actually hit
    body='<html><head><title>502 Server Error</title></head></html>'
    ;;
  notfound)
    printf 'gh: Not Found (HTTP 404)\n' >&2
    exit 1
    ;;
  rate403)   # GitHub's rate limit also arrives as 403 — the inversion this suite pins
    printf 'gh: API rate limit exceeded for user ID 12345. (HTTP 403)\n' >&2
    exit 1
    ;;
esac
expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) expr="$2"; shift 2 ;;
    --paginate) shift ;;
    *) shift ;;
  esac
done
if [ -n "$expr" ]; then
  printf '%s' "$body" | jq -r "$expr" || exit 1
else
  printf '%s' "$body"
fi
FAKE
chmod +x "$TMP/bin/gh"

run_script() { # $1 = script path, $2 = out file, $3 = fake-gh mode
  FAKE_GH_MODE="$3" PATH="$TMP/bin:$PATH" GH_REPO=daniel-ospina/agent-infra \
    bash "$1" 1863 >"$2" 2>&1
  return $?
}

# ── 1. non-JSON body: tooling verdict, never a policy verdict, fail closed
run_script "$SCRIPT" "$TMP/nonjson.out" nonjson
rc=$?
grep -q "did not answer with JSON" "$TMP/nonjson.out" \
  && ok  "non-JSON body => BLOCKED-BY-TOOLING (parse failure named)" \
  || bad "non-JSON body => BLOCKED-BY-TOOLING (parse failure named)" "$(grep -m1 'fetch' "$TMP/nonjson.out")"
grep -qi "PIPELINE COMPLIANCE: BLOCKED" "$TMP/nonjson.out" \
  && bad "a parse failure must not reach the compliance verdict" "verdict line present" \
  || ok  "a parse failure does not reach the compliance verdict"
[[ $rc -eq 2 ]] && ok "an unreadable PR fails CLOSED with exit 2" \
  || bad "an unreadable PR fails CLOSED with exit 2" "exit=$rc"

# ── 2. THE INVERSION: a 403 rate limit is transient, not an access defect
run_script "$SCRIPT" "$TMP/403.out" rate403
grep -q "TRANSIENT condition" "$TMP/403.out" \
  && ok  "403 rate limit => transient advice (re-run)" \
  || bad "403 rate limit => transient advice (re-run)" "$(grep -m1 'VERDICT' "$TMP/403.out")"
grep -q "reference or access defect" "$TMP/403.out" \
  && bad "a rate limit must not be called an access defect" "access-defect wording present" \
  || ok  "a rate limit is not called an access defect"

# ── 3. a plain 404 is a reference/access defect (permanent)
run_script "$SCRIPT" "$TMP/404.out" notfound
grep -q "reference or access defect" "$TMP/404.out" \
  && ok  "404 => reference/access advice (permanent)" \
  || bad "404 => reference/access advice (permanent)" "$(grep -m1 'VERDICT' "$TMP/404.out")"

# ── 4. a warning on a SUCCESSFUL call is surfaced, never consumed as payload
run_script "$SCRIPT" "$TMP/ok.out" ok
grep -qi "warning (ignored" "$TMP/ok.out" \
  && ok  "the ignored warning is surfaced rather than dropped" \
  || bad "the ignored warning is surfaced rather than dropped" "no 'warning (ignored' line"

# ── 6. MUTATION: restore the old single-message failure path; class 1 must go red.
python3 - "$SCRIPT" "$TMP/mutant.sh" <<'MUT'
import sys
src = open(sys.argv[1]).read()
start = src.find('    # FOUR classes, ordered by what the operator must DO')
end = src.find('    rm -f "$err"; exit 2', start)
assert start != -1 and end != -1, "mutation anchor not found — the suite must not pass silently"
old = ('    echo "❌ [fetch] gh api failed for repos/$repo/$path (exit $rc): $out" >&2\n'
       '    echo "   Check GH_REPO, PR_NUMBER, and gh auth." >&2\n')
open(sys.argv[2], 'w').write(src[:start] + old + src[end:])
MUT
if grep -q 'exit $rc): \$out' "$TMP/mutant.sh"; then
  run_script "$TMP/mutant.sh" "$TMP/mutant.out" nonjson
  grep -q "did not answer with JSON" "$TMP/mutant.out" \
    && bad "mutation: the old message shape must fail class 1" "mutant still produced the new verdict — assertion is vacuous" \
    || ok  "mutation: restoring the old message shape fails class 1 (the test can fail)"
  run_script "$TMP/mutant.sh" "$TMP/mutant403.out" rate403
  grep -q "TRANSIENT condition" "$TMP/mutant403.out" \
    && bad "mutation: the old shape must also fail the rate-limit class" "mutant classified a 403 rate limit" \
    || ok  "mutation: the old shape also fails the rate-limit class"
else
  bad "mutation harness produced the old shape" "anchor rewrite did not apply"
fi

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
