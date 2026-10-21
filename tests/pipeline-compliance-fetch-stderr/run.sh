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
# The fetch site read `out="$(gh api … 2>&1)"`, so whatever gh wrote on STDERR was
# merged into the value the gate reads. On CI the result is indistinguishable from a
# policy violation, so a transient gh warning reads as "seven broken branches" and
# blocks the whole landing queue. #1876 is the general form of this bug; this is its
# occurrence in the fetch path.
#
# WHAT THIS SUITE PROVES — three properties, and nothing it cannot observe:
#
#  1. SEPARATION. A warning on a SUCCESSFUL call is surfaced on stderr and never
#     enters the fetched VALUE. The fixture's warning is emitted WITHOUT a trailing
#     newline on purpose: that is the shape that corrupts a value, because with the
#     streams merged it is GLUED onto the first line of gh's stdout. So the property
#     is observable end-to-end — the gate still reads the PR body's line-leading
#     `Refs #1012` and check (a) PASSES.
#  2. NON-VACUITY (the mutation). The SAME fixture against the pre-fix `2>&1` shape
#     must FAIL that claim: the glued warning destroys the line-leading reference, and
#     the gate reports a FALSE policy verdict ("no linked issue") for a PR that has
#     one. A suite that stayed green on the old code would prove nothing, so the
#     mutation is asserted and fails the run if it does not corrupt the read.
#  3. THE FAILURE PATH IS A TOOLING VERDICT, NOT A POLICY ONE — a FAILED call reports
#     its exit code, gh's stderr and `VERDICT: BLOCKED-BY-TOOLING`, and still fails
#     CLOSED (exit 2). This is the half the gate needs so a gh outage can never read
#     as non-compliance; before this change the branch was never exercised at all.
#
# Hermetic: a fake `gh` serves every call and emulates `gh api --jq` with real jq
# (the gate already requires jq), so the expressions the gate passes are applied by
# the fixture exactly as gh would apply them. No network, no auth, no real PR.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/check-pipeline-compliance.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pc-fetch-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

checks=0
failures=0
ok()   { checks=$((checks + 1)); printf '  PASS %s\n' "$1"; }
bad()  { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

command -v jq >/dev/null 2>&1 || {
  echo "  SKIP jq is not installed — the fixture cannot emulate 'gh api --jq', so the"
  echo "       read path cannot be exercised faithfully. This suite CANNOT pass here."
  exit 1
}

# ── the fixture: `gh api <path> [--paginate] --jq <expr>`, with a benign warning on
#    stderr and NO trailing newline (see (1) above), and a GH_FAKE_FAIL mode that
#    exits 1 with its own stderr diagnostic.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
path=""; expr=""; prev=""
shift   # drop the `api` subcommand
for a in "$@"; do
  case "$prev" in --jq) expr="$a" ;; esac
  case "$a" in --jq|--paginate|-X|-f|-F|--input) ;; *) [ -z "$path" ] && path="$a" ;; esac
  prev="$a"
done
if [[ "${GH_FAKE_FAIL:-}" == "1" ]]; then
  printf 'HTTP 502: Bad Gateway\n' >&2
  printf 'partial body before the failure'
  exit 1
fi
printf 'Warning: API rate limit is near its secondary threshold; continuing' >&2
# The response the REAL API would return for this path. Bare-endpoint lists are
# arrays; the PR object carries the fields the gate's expressions read.
case "$path" in
  */files|*/commits|*/comments|*/labels) body='[]' ;;
  *)
    body='{"body":"Refs #1012","labels":[],"user":{"login":"lane"},"merged":false,
           "state":"open","changed_files":0,"head":{"ref":"x","sha":"df5d6eff6ce8"},
           "title":"t","number":1863,
           "base":{"ref":"main","repo":{"full_name":"daniel-ospina/agent-infra"}}}'
    ;;
esac
printf '%s' "$body" | jq -r "$expr"
exit 0
FAKE
chmod +x "$TMP/bin/gh"

run_script() { # $1 = script path, $2 = out file ; env passes through
  PATH="$TMP/bin:$PATH" GH_REPO=daniel-ospina/agent-infra \
    bash "$1" 1863 >"$2" 2>&1
  return $?
}

# ── 1. the patched script: the value is clean, the warning is surfaced, no false verdict
run_script "$SCRIPT" "$TMP/new.out"
rc=$?
grep -q 'invalid character' "$TMP/new.out" \
  && bad "a warning on a successful call never reaches the value as data" "$(grep -m1 'invalid character' "$TMP/new.out")" \
  || ok  "a warning on a successful call never reaches the value as data"
grep -q '✅ \[a\] linked issue' "$TMP/new.out" \
  && ok  "the fetched PR body is read INTACT (its line-leading 'Refs #1012' resolves)" \
  || bad "the fetched PR body is read INTACT (its line-leading 'Refs #1012' resolves)" \
         "$(grep -m2 -E '\[a\]|warning' "$TMP/new.out")"
grep -qi 'warning (ignored' "$TMP/new.out" \
  && ok  "the ignored warning is surfaced on stderr rather than dropped" \
  || bad "the ignored warning is surfaced on stderr rather than dropped" "no 'warning (ignored' line in output"
[[ $rc -ne 2 ]] \
  && ok "a readable response is not reported as BLOCKED-BY-TOOLING" \
  || bad "a readable response is not reported as BLOCKED-BY-TOOLING" "script exited 2"

# ── 2. non-vacuous: the SAME fixture against the pre-fix stderr-merged code must FAIL (1)
sed 's|2>"\$err")|2>\&1)|' "$SCRIPT" > "$TMP/merged.sh"
grep -q '2>&1)' "$TMP/merged.sh" \
  || bad "mutation harness built the stderr-merged variant" "sed did not rewrite the redirect"
run_script "$TMP/merged.sh" "$TMP/merged.out"
if grep -q 'no linked issue' "$TMP/merged.out"; then
  ok "mutation: merging stderr CORRUPTS the read — the gate reports a FALSE policy verdict for a body that carries 'Refs #1012' (so this suite can fail)"
else
  bad "mutation: merging stderr CORRUPTS the read — the gate reports a FALSE policy verdict for a body that carries 'Refs #1012' (so this suite can fail)" \
      "the merged variant still read the body — the assertion is vacuous"
fi

# ── 3. a FAILED call is a TOOLING verdict that still fails closed
GH_FAKE_FAIL=1 run_script "$SCRIPT" "$TMP/fail.out"
fail_rc=$?
grep -q 'VERDICT: BLOCKED-BY-TOOLING' "$TMP/fail.out" \
  && ok "a FAILED fetch states VERDICT: BLOCKED-BY-TOOLING" \
  || bad "a FAILED fetch states VERDICT: BLOCKED-BY-TOOLING" "$(sed -n '1,6p' "$TMP/fail.out")"
grep -q 'stderr: HTTP 502' "$TMP/fail.out" \
  && ok "a FAILED fetch reports gh's stderr verbatim" \
  || bad "a FAILED fetch reports gh's stderr verbatim" "no 'stderr: HTTP 502' line in output"
grep -q 'stdout: partial body' "$TMP/fail.out" \
  && ok "a FAILED fetch reports what stdout DID carry" \
  || bad "a FAILED fetch reports what stdout DID carry" "no 'stdout: partial body' line in output"
grep -q '✅ \[a\]' "$TMP/fail.out" \
  && bad "a FAILED fetch reports NO policy verdict" "a check verdict was printed for an unreadable PR" \
  || ok  "a FAILED fetch reports NO policy verdict"
[[ $fail_rc -eq 2 ]] \
  && ok "a FAILED fetch still fails CLOSED (exit 2)" \
  || bad "a FAILED fetch still fails CLOSED (exit 2)" "exit $fail_rc"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[[ $failures -eq 0 ]]
