#!/usr/bin/env bash
# tests/pipeline-compliance-fetch-stderr/run.sh — stderr must never enter the JSON stream.
#
# WHY. Measured 2026-10-21 on agent-infra: pipeline-compliance was RED on SEVEN of nine
# finished PRs (#1863 #2025 #2172 #1858 #1881 #1553 #1913) while ~20 other checks were
# green on the same sha. Reproduced locally:
#
#   ❌ [fetch] gh api failed for repos/daniel-ospina/agent-infra/pulls/1863 (exit 1):
#      invalid character 'S' looking for beginning of value
#
# That is jq's PARSE error, surfaced as though the caller had passed a bad path. The
# fetch site read `out="$(gh api … 2>&1)"`, so ONE warning line on an otherwise
# successful call fed non-JSON into the --jq filter. On CI the result is
# indistinguishable from a policy violation, so a transient gh warning reads as
# "seven broken branches" and blocks the whole landing queue. #1876 is the general
# form of this bug; this is its occurrence in the fetch path.
#
# WHAT IS ASSERTED. A warning on a successful call is SURFACED, never PARSED: the run
# must not report a parse error and must not claim a policy failure. And the test is
# non-vacuous — the same fixture against a script that merges stderr must FAIL, which
# is asserted in the last check.
#
# Hermetic: a fake `gh` serves every call; no network, no auth, no real PR.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-pipeline-compliance.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pc-fetch-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checks=0
failures=0
ok()   { checks=$((checks + 1)); printf '  PASS %s\n' "$1"; }
bad()  { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# ── the fixture: success exit code, valid JSON on stdout, a benign warning on stderr
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf 'Warning: API rate limit is near its secondary threshold; continuing\n' >&2
cat <<'JSON'
{"body":"Refs #1012","labels":[],"user":{"login":"lane"},"merged":false,"state":"open",
 "changed_files":2,"head":{"ref":"x"},"title":"t","number":1863,
 "base":{"ref":"main","repo":{"full_name":"daniel-ospina/agent-infra"}},
 "files":[],"commits":[]}
JSON
exit 0
FAKE
chmod +x "$TMP/bin/gh"

run_script() { # $1 = script path, $2 = out file
  PATH="$TMP/bin:$PATH" GH_REPO=daniel-ospina/agent-infra \
    bash "$1" 1863 >"$2" 2>&1
  return $?
}

# ── 1. the patched script: no parse error, warning surfaced, not a policy verdict
run_script "$SCRIPT" "$TMP/new.out"
rc=$?
grep -q "invalid character" "$TMP/new.out" \
  && bad "warning on a successful call must not reach jq as JSON" "$(grep -m1 'invalid character' "$TMP/new.out")" \
  || ok  "warning on a successful call is not parsed as JSON"
grep -qi "warning (ignored" "$TMP/new.out" \
  && ok  "the ignored warning is surfaced on stderr rather than dropped" \
  || bad "the ignored warning is surfaced on stderr rather than dropped" "no 'warning (ignored' line in output"
[[ $rc -ne 2 ]] \
  && ok "a readable response is not reported as BLOCKED-BY-TOOLING" \
  || bad "a readable response is not reported as BLOCKED-BY-TOOLING" "script exited 2"

# ── 2. non-vacuous: the SAME fixture against stderr-merged code must fail this suite
sed 's|2>"\$err")|2>\&1)|' "$SCRIPT" > "$TMP/merged.sh"
grep -q '2>&1)' "$TMP/merged.sh" \
  || bad "mutation harness built the stderr-merged variant" "sed did not rewrite the redirect"
run_script "$TMP/merged.sh" "$TMP/merged.out"
if grep -q "invalid character" "$TMP/merged.out"; then
  ok "mutation: merging stderr reproduces the parse error (the test can fail)"
else
  bad "mutation: merging stderr reproduces the parse error (the test can fail)" \
      "no parse error with stderr merged — the assertion is vacuous"
fi

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
