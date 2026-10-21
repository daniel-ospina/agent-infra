#!/usr/bin/env bash
# tests/pipeline-compliance-fetch-stderr/run.sh — a jq PARSE error is not a policy verdict.
#
# WHY. Measured 2026-10-21 on agent-infra: pipeline-compliance was RED on SEVEN of nine
# finished PRs (#1863 #2025 #2172 #1858 #1881 #1553 #1913) while ~20 other checks were
# green on the same sha. Reproduced locally:
#
#   ❌ [fetch] gh api failed for repos/daniel-ospina/agent-infra/pulls/1863 (exit 1):
#      invalid character 'S' looking for beginning of value
#
# `invalid character … looking for beginning of value` is JQ failing to parse the body
# the API returned — a 5xx/rate-limit/proxy page, not JSON. `fetch_json` printed that
# parse error and nothing else, so on CI an API that could not answer was
# INDISTINGUISHABLE from a PR that violates policy. The first diagnosis of this defect
# (stderr merged into the jq stream by `2>&1`) was WRONG: the initial fixture proved
# it could not reproduce the message, which is why the mutation below simulates the
# real thing — a non-JSON body — instead of a warning on stderr.
#
# What is asserted:
#   1. non-JSON response => BLOCKED-BY-TOOLING naming the parse failure, never a policy verdict
#   2. 404 => reference/access advice (permanent), not "transient, re-run"
#   3. success WITH a warning on stderr => clean JSON parsed, warning surfaced, not parsed
#   4. a failing gh exits 2 (fail closed) — the branch is reachable, not dead code
#   5. MUTATION: restore the old single-message path and the class-1 assertion must FAIL,
#      so the suite cannot pass vacuously.
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

# ── fake gh. Mirrors the real gh's contract that matters here: `--jq <expr>` runs jq
# over the RESPONSE BODY, so a non-JSON body makes gh itself fail with jq's message.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
mode="${FAKE_GH_MODE:-ok}"
case "$mode" in
  ok)
    body='{"body":"Refs #1012","labels":[],"user":{"login":"lane"},"merged":false,"state":"open","changed_files":2,"head":{"ref":"x"},"title":"t","number":1863,"base":{"ref":"main","repo":{"full_name":"daniel-ospina/agent-infra"}},"files":[],"commits":[]}'
    printf 'Warning: API rate limit is near its secondary threshold; continuing\n' >&2
    ;;
  nonjson)   # a 502/rate-limit/proxy page instead of JSON
    body='<html><head><title>502 Server Error</title></head></html>'
    ;;
  notfound)
    printf 'gh: Not Found (HTTP 404)\n' >&2
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

# ── 1. non-JSON response must not read as a policy verdict
run_script "$SCRIPT" "$TMP/nonjson.out" nonjson
rc=$?
grep -q "did not answer with JSON" "$TMP/nonjson.out" \
  && ok  "non-JSON body => BLOCKED-BY-TOOLING (parse failure named)" \
  || bad "non-JSON body => BLOCKED-BY-TOOLING (parse failure named)" "$(grep -m1 'fetch' "$TMP/nonjson.out")"
grep -qi "PIPELINE COMPLIANCE: BLOCKED" "$TMP/nonjson.out" \
  && bad "a parse failure must not reach the compliance verdict" "verdict line present" \
  || ok  "a parse failure does not reach the compliance verdict"
[[ $rc -eq 2 ]] && ok "unreadable PR fails CLOSED with exit 2" \
  || bad "unreadable PR fails CLOSED with exit 2" "exit=$rc"

# ── 2. 404 is a reference/access defect, not a transient one
run_script "$SCRIPT" "$TMP/404.out" notfound
grep -q "reference or access defect" "$TMP/404.out" \
  && ok  "404 => reference/access advice (permanent), not 're-run'" \
  || bad "404 => reference/access advice (permanent), not 're-run'" "$(grep -m1 'VERDICT' "$TMP/404.out")"

# ── 3. a warning on a SUCCESSFUL call is surfaced, never parsed
run_script "$SCRIPT" "$TMP/ok.out" ok
grep -q "invalid character" "$TMP/ok.out" \
  && bad "warning on success is not parsed as JSON" "$(grep -m1 'invalid character' "$TMP/ok.out")" \
  || ok  "warning on success is not parsed as JSON"
grep -qi "warning (ignored" "$TMP/ok.out" \
  && ok  "the ignored warning is surfaced rather than dropped" \
  || bad "the ignored warning is surfaced rather than dropped" "no 'warning (ignored' line"

# ── 4/5. MUTATION: restore the old single-message failure path; class 1 must go red.
python3 - "$SCRIPT" "$TMP/mutant.sh" <<'MUT'
import sys, re
src = open(sys.argv[1]).read()
start = src.find('    # A PERMANENT failure and a TRANSIENT one need different advice.')
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
else
  bad "mutation harness produced the old shape" "anchor rewrite did not apply"
fi

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
