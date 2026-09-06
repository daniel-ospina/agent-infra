#!/usr/bin/env bash
# deepseek-balance-watch.test.sh — self-check for deepseek-balance-watch.sh +
# deepseek-balance-latch.py (#476 Phase 5 poller). Network-free: DBW_CURL_STATE
# supplies canned per-URL probe outputs, DBW_STATE_FILE redirects latch state
# to a temp dir, DBW_KEY/DBW_OR_KEY bypass key resolution, DBW_LOG captures.
#
# Run: bash scripts/checkout-hygiene/deepseek-balance-watch.test.sh
# Exits 0 when ALL assertions pass, 1 on any failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/deepseek-balance-watch.sh"
LATCH="$SCRIPT_DIR/deepseek-balance-latch.py"

PASS=0
FAIL=0
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

SIM="$T/sim"; ST="$T/state/provider-exhaustion.json"; CONSEC="$T/consec"
export DBW_STATE_FILE="$ST"
mkdir -p "$SIM" "$T/state"
touch "$CONSEC"

ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

assert_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing: $2)"; fi
}
assert_not_contains() { # <haystack> <needle> <label>
  if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi
}

# Canned-probe helpers (write the balance/chat/openrouter response files).
BSLUG="$(printf '%s' "https://api.deepseek.com/user/balance" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -c1-12)"
CSLUG="$(printf '%s' "https://api.deepseek.com/chat/completions" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -c1-12)"
OSLUG="$(printf '%s' "https://openrouter.ai/api/v1/auth/key" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -c1-12)"
bal()   { printf '%s\n200\n0.8\n' "$1" > "$SIM/out.$BSLUG"; }
resp()  { printf '%s\n%s\n0.8\n' "$2" "$1" > "$SIM/out.$BSLUG"; }  # resp <code> <body>
chat()  { printf '%s\n200\n1.1\n' "$1" > "$SIM/out.$CSLUG"; }
or()    { printf '%s\n200\n0.9\n' "$1" > "$SIM/out.$OSLUG"; }
or_resp() { printf '%s\n%s\n0.9\n' "$2" "$1" > "$SIM/out.$OSLUG"; }  # or_resp <code> <body>
reset() { rm -f "$ST"; : > "$CONSEC"; rm -f "$CONSEC.or"; chat '{"choices":[{"message":{"content":"OK"}}]}'; }

LAST_OUT=""
# watch <want_exit> <label> [VAR=val ...]
watch() {
  local want="$1" label="$2"; shift 2
  local envs=() args=()
  for a in "$@"; do
    if [[ "$a" == *=* ]]; then envs+=("$a"); else args+=("$a"); fi
  done
  local log="$T/run.log" rc out
  : > "$log"
  out="$(cd "$T" && env -i HOME="$HOME" PATH="$PATH" \
    DBW_KEY=test DBW_STATE_FILE="$ST" DBW_CURL_STATE="$SIM" DBW_LOG="$log" \
    DBW_LATCH_PY="$LATCH" DBW_OR_KEY=or-test DBW_CONSEC_FILE="$CONSEC" \
    ${envs[@]+"${envs[@]}"} \
    bash "$CHECK" ${args[@]+"${args[@]}"} 2>&1)" && rc=0 || rc=$?
  LAST_OUT="$out"
  if [ "$rc" = "$want" ]; then ok "$label (exit $rc)"; else bad "$label (exit $rc, want $want)"; fi
}
latched() {
  if python3 "$LATCH" status 2>/dev/null | python3 -c 'import json,sys; p=json.load(sys.stdin).get("primaries",{}).get("deepseek"); sys.exit(0 if (p and p.get("status")=="exhausted") else 1)'; then
    ok "$1"; else bad "$1"; fi
}
not_latched() {
  if python3 "$LATCH" status 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if "deepseek" not in json.load(sys.stdin).get("primaries",{}) else 1)'; then
    ok "$1"; else bad "$1"; fi
}
seed_latch() { python3 "$LATCH" set --primary deepseek >/dev/null 2>&1; }

echo "── healthy / clear-path ──"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"91.43","granted_balance":"0.00","topped_up_balance":"91.43"}]}'
or '{"data":{"label":"k","limit_remaining":58.93,"is_free_tier":false}}'
watch 0 "PASS on healthy high balance"
assert_contains "$LAST_OUT" "PASS balance=USD 91.4300" "PASS line records balance"
assert_contains "$LAST_OUT" "PASS openrouter limit_remaining=USD 58.9300" "openrouter leg healthy reported"
not_latched "no latch on healthy"
: > "$SIM/requests.log"  # reset per-scenario request ledger
watch 0 "healthy (no latch) never chats — zero token spend"
if grep -q "chat/completions" "$SIM/requests.log"; then bad "chat probe fired with no latch (token leak)"; else ok "no chat probe with no latch"; fi

echo "── CNY multi-currency parse (s6 string-typed hazard) ──"
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"45.00","granted_balance":"0.00","topped_up_balance":"45.00"},{"currency":"CNY","total_balance":"320.50","granted_balance":"0.00","topped_up_balance":"320.50"}]}'
watch 0 "PASS with CNY + USD entries (USD keyed)"
assert_contains "$LAST_OUT" "balance=USD 45.0000" "USD entry keyed for spend decisions"

echo "── low balance → SET ──"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.00","granted_balance":"0.00","topped_up_balance":"2.00"}]}'
watch 0 "SET on balance at/below low threshold"
assert_contains "$LAST_OUT" "SET balance=USD 2.0000" "SET line records balance"
latched "latch record written (status exhausted)"
python3 "$LATCH" status | python3 -c 'import json,sys; p=json.load(sys.stdin)["primaries"]["deepseek"]; assert p["reason"]=="low_balance" and p["source"]=="poller"; print("  ✅ poller source + low_balance reason stamped")'

echo "── hysteresis: mid-band holds, never clears ──"
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.00","granted_balance":"0.00","topped_up_balance":"12.00"}]}'
watch 0 "mid-band balance → HOLD (latch untouched)"
assert_contains "$LAST_OUT" "HOLD balance=USD 12.0000" "HOLD line records band"
latched "existing latch preserved in mid-band (hysteresis)"

echo "── restore: verified positive + chat probe → CLEAR ──"
seed_latch
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"91.43","granted_balance":"0.00","topped_up_balance":"91.43"}]}'
watch 0 "CLEAR on verified positive balance + probe 200"
assert_contains "$LAST_OUT" "CLEAR balance=USD 91.4300" "CLEAR line records balance"
not_latched "latch cleared after restore"

echo "── clear deferred when chat probe fails (fail-closed) ──"
reset; seed_latch
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"50.00","granted_balance":"0.00","topped_up_balance":"50.00"}]}'
printf 'err\n503\n2.0\n' > "$SIM/out.$CSLUG"
watch 1 "balance restored but chat-probe 503 → HOLD (deferred clear, exit 1)"
assert_contains "$LAST_OUT" "HOLD balance=USD 50.0000 but chat-probe http=503" "deferred-clear HOLD logged"
latched "latch kept when probe fails (fail-closed)"
chat '{"choices":[{"message":{"content":"OK"}}]}'

echo "── auth / network / schema failures (never latch) ──"
reset
resp 401 '{"error":{"message":"Authentication Fails"}}'
watch 0 "401 → SKIP (never latch on auth failure)"
assert_contains "$LAST_OUT" "SKIP http=401" "SKIP logged"
not_latched "no latch on 401"
resp 401 '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"1.00","granted_balance":"0.00","topped_up_balance":"1.00"}]}'
watch 0 "401 body with a low balance never latches either"
assert_contains "$LAST_OUT" "SKIP http=401" "second 401 still SKIP"
not_latched "auth failure never SETs even at ~0 balance"
reset
resp 200 '{"weird":"shape"}'
watch 1 "schema drift → no action + exit 1"
assert_contains "$LAST_OUT" "SCHEMA-DRIFT" "schema-drift alert logged"
not_latched "schema drift never latches"
resp 000 ''
watch 1 "curl timeout → FAIL + exit 1"
assert_contains "$LAST_OUT" "FAIL http=timeout" "timeout logged"
resp 503 'err'
watch 1 "http 503 → DEFER + exit 1"
assert_contains "$LAST_OUT" "DEFER http=503" "defer logged"

echo "── escalation after consecutive failures ──"
reset
resp 000 ''
watch 1 "first degraded run"
watch 1 "second degraded run"
watch 1 "third degraded run escalates"
assert_contains "$LAST_OUT" "ESCALATE 3 consecutive" "escalation after 3 degraded runs"
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"88.00","granted_balance":"0.00","topped_up_balance":"88.00"}]}'
watch 0 "recovery clears the consec counter"
assert_not_contains "$LAST_OUT" "ESCALATE" "no escalation after recovery"

echo "── openrouter leg alerts ──"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"88.00","granted_balance":"0.00","topped_up_balance":"88.00"}]}'
or '{"data":{"label":"k","limit_remaining":3.20,"is_free_tier":false}}'
watch 1 "openrouter below min → ALERT + exit 1"
assert_contains "$LAST_OUT" "ALERT openrouter limit_remaining=USD 3.2000 below" "openrouter low alert logged"
or '{"data":{"label":"k","limit_remaining":58.93,"is_free_tier":false}}'
watch 0 "openrouter recovered → PASS"
assert_contains "$LAST_OUT" "PASS openrouter" "openrouter healthy logged"

echo "── boundary + account-state + latch-write failure (review fixes) ──"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"5.00","granted_balance":"0.00","topped_up_balance":"5.00"}]}'
watch 0 "balance EXACTLY == LOW (5.00) → SET (boundary inclusive)"
assert_contains "$LAST_OUT" "SET balance=USD 5.0000" "SET at boundary logged"
latched "boundary latches (at/below semantics)"
reset
bal '{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"50.00","granted_balance":"0.00","topped_up_balance":"50.00"}]}'
watch 1 "is_available=false → ACCOUNT-UNAVAILABLE + exit 1 (never a false PASS)"
assert_contains "$LAST_OUT" "ACCOUNT-UNAVAILABLE" "unusable account logged"
not_latched "no latch change on unusable account (defer; 402 markers backstop)"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.00","granted_balance":"0.00","topped_up_balance":"2.00"}]}'
chmod 555 "$T/state"
watch 1 "durable latch write fails → LATCH-SET-FAILED + exit 1"
chmod 755 "$T/state"
assert_contains "$LAST_OUT" "LATCH-SET-FAILED" "write failure reported"
assert_not_contains "$LAST_OUT" "latch SET" "no false SET claim on failed write"
not_latched "no latch record when the write failed"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"88.00","granted_balance":"0.00","topped_up_balance":"88.00"}]}'
or_resp 000 ''
watch 1 "OR 000 first degraded run"
watch 1 "OR 000 second degraded run"
watch 1 "OR 000 third degraded run escalates (OR counter, exit 1)"
assert_contains "$LAST_OUT" "ESCALATE-OR 3 consecutive" "OR liveness escalates after 3"
assert_not_contains "$LAST_OUT" "ESCALATE " "OR failures never emit the deepseek ESCALATE (dedicated counter)"
or '{"data":{"label":"k","limit_remaining":58.93,"is_free_tier":false}}'
watch 0 "OR recovery clears the OR counter"
reset
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"88.00","granted_balance":"0.00","topped_up_balance":"88.00"}]}'
printf '2\n' > "$CONSEC.or"
watch 0 "keyless OR run (skip) resets a stale OR streak" HOME="$T/nohome" DBW_OR_KEY=
[ ! -f "$CONSEC.or" ] && ok "stale OR counter cleared on keyless skip" || bad "stale OR counter survived keyless skip"


reset
mkdir -p "$T/nohome"
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.00","granted_balance":"0.00","topped_up_balance":"2.00"}]}'
watch 0 "no deepseek key → SKIP" HOME="$T/nohome" DBW_KEY=
assert_contains "$LAST_OUT" "SKIP no deepseek api key" "missing key skip logged"
not_latched "no latch written without a key"
seed_latch
bal '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"2.00","granted_balance":"0.00","topped_up_balance":"2.00"}]}'
watch 0 "DBW_DRY computes SET but never mutates state" DBW_DRY=1
assert_contains "$LAST_OUT" "[dry-run] latch action skipped" "dry-run announces latch action"
latched "dry-run never mutates (existing latch preserved, no new write)"
python3 "$LATCH" clear --primary deepseek >/dev/null 2>&1
watch 2 "usage error on unexpected arg" --bogus
assert_contains "$LAST_OUT" "usage:" "usage printed"

echo ""
echo "deepseek-balance-watch.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
