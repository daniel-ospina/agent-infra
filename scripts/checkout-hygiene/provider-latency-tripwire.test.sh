#!/usr/bin/env bash
# provider-latency-tripwire.test.sh — self-check for scripts/checkout-hygiene/provider-latency-tripwire.sh
# (#413/#424). Network-free: PLT_CURL_OUT supplies canned probe output, GH_BIN
# stubs the gh CLI, PLT_KEY bypasses key resolution.
#
# Run: bash scripts/checkout-hygiene/provider-latency-tripwire.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/provider-latency-tripwire.sh"

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LAST_OUT=""

# gh stub — records create/comment calls to $STUB_LOG; issue list honours
# $STUB_LIST_OUT (number of an "already open" issue, default: none).
cat > "$TMP/gh-stub" <<'STUB'
#!/usr/bin/env bash
case "$1 $2 $3" in
  "issue list --repo")
    printf '%s' "${STUB_LIST_OUT:-}" ;;
  "issue create --repo")
    { printf 'CREATE\n'; printf 'ARGS:%s\n' "$*"; } >> "${STUB_LOG:-/dev/null}"
    echo "https://github.com/example/agent-infra/issues/424" ;;
  "issue comment --repo")
    { printf 'COMMENT\n'; printf 'ARGS:%s\n' "$*"; } >> "${STUB_LOG:-/dev/null}" ;;
  *)
    echo "STUB-UNHANDLED: $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$TMP/gh-stub"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}

assert_not_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

# trip <want_exit> <label> [VAR=val ...] [--dry-run]
#   Runs the checker with env overrides; records output in $LAST_OUT and gh
#   stub calls in $TMP/last.stub. Exit-code assertion prints visibly.
trip() {
  local want="$1" label="$2"; shift 2
  local envs=() args=()
  for a in "$@"; do
    if [[ "$a" == *=* ]]; then envs+=("$a"); else args+=("$a"); fi
  done
  local log="$TMP/run.log" stub_log="$TMP/stub.log" rc out
  : > "$stub_log"; : > "$log"
  out="$(cd "$TMP" && env -i HOME="$HOME" PATH="$PATH" PLT_KEY=test PLT_LOG="$log" \
    GH_BIN="$TMP/gh-stub" STUB_LOG="$stub_log" ${envs[@]+"${envs[@]}"} \
    bash "$CHECK" ${args[@]+"${args[@]}"} 2>&1)" && rc=0 || rc=$?
  LAST_OUT="$out"
  cp "$stub_log" "$TMP/last.stub" 2>/dev/null || : > "$TMP/last.stub"
  if [ "$rc" = "$want" ]; then ok "$label (exit $rc)"; else bad "$label (exit $rc, want $want)"; fi
}

echo "── healthy (200 fast) ──"
trip 0 "PASS on http 200 under threshold" PLT_CURL_OUT=$'ok\n200\n0.5'
assert_contains "$LAST_OUT" "PASS http=200 wall=0.5s" "log line records PASS"

echo "── slow (regression) ──"
trip 1 "FAIL on http 200 over threshold" PLT_CURL_OUT=$'ok\n200\n20.0'
assert_contains "$LAST_OUT" "FAIL http=200 wall=20.0s" "log line records FAIL"
assert_contains "$(cat "$TMP/last.stub")" "CREATE" "alert filed (create)"
assert_contains "$LAST_OUT" "opened provider-latency issue" "create reported to stderr"
trip 1 "alert title carries latency" PLT_CURL_OUT=$'ok\n200\n20.0' PLT_REPO=test/repo
assert_contains "$(cat "$TMP/last.stub")" "20.0s" "title includes measured latency"

echo "── dedup ──"
trip 1 "dedup: comments on existing open issue" PLT_CURL_OUT=$'ok\n200\n20.0' STUB_LIST_OUT=7
assert_contains "$(cat "$TMP/last.stub")" "COMMENT" "comment path taken"
assert_not_contains "$(cat "$TMP/last.stub")" "CREATE" "no second issue created"

echo "── provider errors ──"
trip 1 "FAIL on http 503" PLT_CURL_OUT=$'err\n503\n2.0'
assert_contains "$(cat "$TMP/last.stub")" "CREATE" "503 alerts"
trip 1 "FAIL on curl timeout (empty output)" PLT_CURL_OUT=""
assert_contains "$LAST_OUT" "timeout" "timeout reported"
assert_contains "$(cat "$TMP/last.stub")" "CREATE" "timeout alerts"

echo "── skips (not latency conditions) ──"
trip 0 "SKIP on http 401" PLT_CURL_OUT=$'err\n401\n0.1'
assert_contains "$LAST_OUT" "SKIP http=401" "401 logged as skip"
assert_not_contains "$(cat "$TMP/last.stub")" "CREATE" "no alert on auth failure"
mkdir -p "$TMP/nohome"
trip 0 "SKIP when no api key" PLT_KEY= HOME="$TMP/nohome"
assert_contains "$LAST_OUT" "SKIP no api key" "missing key logged"

echo "── dry-run + usage ──"
trip 1 "dry-run FAIL files nothing" PLT_CURL_OUT=$'ok\n200\n20.0' --dry-run
assert_contains "$LAST_OUT" "would file" "dry-run announces"
assert_not_contains "$(cat "$TMP/last.stub")" "CREATE" "dry-run never calls gh"
trip 2 "usage error on bad arg" --bogus
assert_contains "$LAST_OUT" "usage:" "usage printed"

echo ""
echo "provider-latency-tripwire.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
