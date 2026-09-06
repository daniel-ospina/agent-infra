#!/usr/bin/env bash
# deepseek-balance-watch.sh — balance poller for the #476 provider-exhaustion
# failover. THE single restore authority (issue #476 O/I/T 4): reads the
# DeepSeek-official prepaid balance, sets the shared exhaustion latch at ~0,
# alerts below threshold, and clears ONLY on verified positive balance + a
# 5-token chat probe. Also reports the openrouter hop leg's remaining credit
# (the poller's "probe all latched legs" mechanism, s6).
#
# Launched by com.eldato.deepseek-balance-watch (templates/launchd) every 15
# minutes; canonical script copied to ~/.pi/agent/scripts/checkout-hygiene/ by
# pi-bootstrap/setup.sh (#427 real copies — launchd EPERMs symlinks into
# ~/Documents). Latch state written through scripts/checkout-hygiene/
# deepseek-balance-latch.py which mirrors the TS module contract
# (extensions/shared/provider-failover.ts) — poller and sessions interoperate
# on ~/.pi/agent/state/provider-exhaustion.json.
#
# Usage: deepseek-balance-watch.sh
#   Exit 0 = ran clean (healthy, skip, or a latch action was taken + logged);
#   1 = probe/decode failure or escalation (could not determine state);
#   2 = usage.
#
# Env overrides (tests + tuning):
#   DBW_LOW_USD        balance AT/BELOW this → SET exhaustion latch (default 5)
#   DBW_CLEAR_USD      balance AT/ABOVE this (+ probe pass) → CLEAR (default 20)
#   DBW_OR_MIN_USD     openrouter limit_remaining below this → ALERT (default 5)
#   DBW_MAX_TIME_S     curl max-time per probe (default 20)
#   DBW_STAGGER_S      sleep this many seconds at start (fleet stagger; default 0)
#   DBW_LOG            rolling one-line-per-run log (default /tmp/deepseek-balance-watch.log)
#   DBW_STATE_FILE     explicit latch state file (tests; also passed to the latch helper)
#   DBW_KEY            deepseek api key override (default: resolve like the tripwire)
#   DBW_OR_KEY         openrouter api key override (default: resolve; absent → OR report skipped)
#   DBW_CURL_STATE     if SET: simulated-curl state DIR for tests. The poller's
#                      curl wrapper writes "<dir>/last-request" (url) and reads
#                      canned output from "<dir>/out.<slug>" where slug is a
#                      sha1 prefix of the url — pre-create out.balance and
#                      out.chat (and out.openrouter) with the body + the two
#                      trailing lines http_code + time_total (tripwire style).
#   DBW_LATCH_PY       latch helper path (default: sibling deepseek-balance-latch.py)
#   DBW_DRY            any value → compute + log decisions but never mutate state

set -euo pipefail

DBW_LOW_USD="${DBW_LOW_USD:-5}"
DBW_CLEAR_USD="${DBW_CLEAR_USD:-20}"
DBW_OR_MIN_USD="${DBW_OR_MIN_USD:-5}"
MAX_TIME_S="${DBW_MAX_TIME_S:-20}"
STAGGER_S="${DBW_STAGGER_S:-0}"
LOG="${DBW_LOG:-/tmp/deepseek-balance-watch.log}"
LATCH_PY="${DBW_LATCH_PY:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deepseek-balance-latch.py}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CONSEC_FAIL_FILE="${DBW_CONSEC_FILE:-/tmp/deepseek-balance-watch.consec}"

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

usage() { echo "usage: $0" >&2; exit 2; }
[ $# -eq 0 ] || usage

# ── fleet-staggered return (default 0 for the single-host launchd job) ──────
if [ "${STAGGER_S:-0}" -gt 0 ] 2>/dev/null; then sleep "$STAGGER_S"; fi

# ── key resolution (launchd env does not inherit the shell profile) ─────────
resolve_key() { # <var> <env-override>
  local var="$1" override="${2:-}" key="" ref=""
  if [ -n "$override" ]; then printf '%s' "$override"; return; fi
  if [ -f "$HOME/pi-keys.env" ]; then
    key="$(bash -c "source \"$HOME/pi-keys.env\" >/dev/null 2>&1; printf '%s' \"\${$var:-}\"" 2>/dev/null || true)"
  fi
  if [ -z "$key" ] && [ "$var" = "DEEPSEEK_API_KEY" ]; then
    # models.json may hold a literal key or an env-ref ($VAR); only literals
    # are usable here (tripwire precedent). OpenRouter keys are env-only.
    ref="$(python3 -c 'import json,os
try:
    print(json.load(open(os.path.expanduser("~/.pi/agent/models.json")))["providers"]["deepseek"].get("apiKey",""))
except Exception:
    print("")' 2>/dev/null || true)"
    case "$ref" in
      \$*|"") key="" ;;
      *) key="$ref" ;;
    esac
  fi
  printf '%s' "$key"
}

DEEPSEEK_KEY="$(resolve_key DEEPSEEK_API_KEY "${DBW_KEY:-}")"
if [ -z "$DEEPSEEK_KEY" ]; then
  log "$TS SKIP no deepseek api key — poller skipped (not a balance condition)"
  exit 0
fi

# ── simulated-curl seam (DBW_CURL_STATE dir) ─────────────────────────────────
slug_of() { printf '%s' "$1" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum; } | cut -c1-12; }
dbw_curl() { # <url> <extra-curl-args...> → prints body + trailing http_code + time_total
  local url="$1"; shift
  if [ -n "${DBW_CURL_STATE+x}" ]; then
    mkdir -p "$DBW_CURL_STATE"
    printf '%s\n' "$url" >> "$DBW_CURL_STATE/requests.log"
    printf '%s\n' "$url" > "$DBW_CURL_STATE/last-request"
    local out="$DBW_CURL_STATE/out.$(slug_of "$url")"
    if [ -f "$out" ]; then cat "$out"; else printf 'SEAM-MISSING %s\n000\n0' "$out"; fi
    return 0
  fi
  curl -sS -m "$MAX_TIME_S" -w '\n%{http_code}\n%{time_total}' "$@" "$url" 2>/dev/null || printf '\n000\n0'
}

# split a probe triple into BODY / CODE / TIME (read into globals)
probe_triple() { # <output>
  BODY="$(printf '%s\n' "$1" | sed '$d' | sed '$d')"
  CODE="$(printf '%s\n' "$1" | tail -2 | head -1)"
  TIME_T="$(printf '%s\n' "$1" | tail -1)"
  if [ -z "$CODE" ] || ! printf '%s' "$CODE" | grep -qE '^[0-9]{3}$'; then
    CODE="000"; TIME_T=""; BODY=""
  fi
}

gt_float() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
ge_float() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

# ── latch helper wrappers (dry-run gated) ────────────────────────────────────
latch() { # <args...> → rc of the helper (0 ok; non-zero = durable write failed)
  if [ -n "${DBW_DRY:-}" ]; then
    log "$TS [dry-run] latch action skipped: $*"
    return 0
  fi
  python3 "$LATCH_PY" "$@"
}
latch_status() {
  if [ -n "${DBW_DRY:-}" ]; then printf '{"primaries":{},"blockedLegs":{}}'; return 0; fi
  python3 "$LATCH_PY" status 2>/dev/null || printf '{"primaries":{},"blockedLegs":{}}'
}

# ── deepseek balance read (s6 shape) ─────────────────────────────────────────
parse_deepseek_balance() { # <body> → prints "unavailable" when is_available=false;
  # prints "USD_total USD_granted USD_topped [CNY_total]" otherwise; prints
  # nothing on schema drift.
  python3 - "$1" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
infos = d.get("balance_infos")
is_avail = d.get("is_available")
if not isinstance(infos, list) or not isinstance(is_avail, bool):
    sys.exit(0)  # schema drift
if not is_avail:
    print("unavailable")  # account unusable — poller defers (never a false PASS)
    sys.exit(0)
by_cur = {}
for info in infos:
    if not isinstance(info, dict):
        sys.exit(0)
    cur = info.get("currency")
    if not isinstance(cur, str):
        sys.exit(0)
    try:
        by_cur[cur] = {
            "total": float(info.get("total_balance")),
            "granted": float(info.get("granted_balance")),
            "topped": float(info.get("topped_up_balance")),
        }
    except (TypeError, ValueError):
        sys.exit(0)  # string/number parse hazard
if "USD" not in by_cur:
    sys.exit(0)  # spend currency absent — do not guess
u = by_cur["USD"]
cny = by_cur.get("CNY", {}).get("total")
print(f"{u['total']:.4f} {u['granted']:.4f} {u['topped']:.4f} {cny if cny is not None else ''}")
PYEOF
}

# ── openrouter leg read (s6 /auth/key shape) ────────────────────────────────
parse_openrouter_limit() { # <body> → prints limit_remaining or nothing
  python3 - "$1" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
lim = (d.get("data") or {}).get("limit_remaining")
if isinstance(lim, (int, float)):
    print(f"{float(lim):.4f}")
PYEOF
}

ACTION="none"
ALERTED=0

# ── primary probe: deepseek balance ──────────────────────────────────────────
DS_URL="https://api.deepseek.com/user/balance"
RAW="$(dbw_curl "$DS_URL" -H "Authorization: Bearer $DEEPSEEK_KEY")"
probe_triple "$RAW"

if [ "$CODE" = "200" ]; then
  read -r USD_TOTAL USD_GRANTED USD_TOP CYN_TOTAL <<<"$(parse_deepseek_balance "$BODY")" || true
  if [ "${USD_TOTAL:-}" = "unavailable" ]; then
    # is_available=false — account unusable (frozen/blocked/disabled). NOT a
    # balance verdict: defer + escalate (no latch change; session 402 markers
    # backstop). Never a false PASS on an unusable account.
    log "$TS ACCOUNT-UNAVAILABLE is_available=false — no balance verdict (defer + escalate; no latch change)"
    ALERTED=1
  elif [ -z "${USD_TOTAL:-}" ]; then
    log "$TS SCHEMA-DRIFT http=200 body-unexpected ($(printf '%s' "$BODY" | head -c 120)) — no action (schema-drift alert; consecutive escalations below)"
    ALERTED=1
  elif ge_float "$USD_TOTAL" "$DBW_CLEAR_USD"; then
    # verified positive. The chat probe (5-token) runs ONLY when a latch
    # record exists — no latch = nothing to clear = no token spend. Clear is
    # fail-closed: probe must pass or the clear is deferred.
    if python3 "$LATCH_PY" status 2>/dev/null | python3 -c 'import json,sys; print("yes" if "deepseek" in json.load(sys.stdin).get("primaries", {}) else "no")' | grep -q "^yes$"; then
      CHAT_RAW="$(dbw_curl "https://api.deepseek.com/chat/completions" \
        -H "Authorization: Bearer $DEEPSEEK_KEY" -H "Content-Type: application/json" \
        -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Reply with the single word: OK"}],"max_tokens":5}')"
      probe_triple "$CHAT_RAW"
      if [ "$CODE" = "200" ]; then
        if latch clear --primary deepseek --reason poller; then
          latch ledger --event poller-clear --provider deepseek --detail "balance USD ${USD_TOTAL} >= clear ${DBW_CLEAR_USD} + probe 200"
          log "$TS CLEAR balance=USD ${USD_TOTAL} (granted ${USD_GRANTED} / topped ${USD_TOP}) probe=200 — exhaustion latch cleared"
          ACTION="pass"
        else
          log "$TS LATCH-CLEAR-FAILED balance=USD ${USD_TOTAL} probe=200 — durable clear write failed; latch kept (fail-closed)"
          ALERTED=1
        fi
      else
        log "$TS HOLD balance=USD ${USD_TOTAL} but chat-probe http=${CODE} — clear deferred (fail-closed; a dead endpoint is not a restored balance)"
        ALERTED=1
      fi
    else
      log "$TS PASS balance=USD ${USD_TOTAL} (granted ${USD_GRANTED} / topped ${USD_TOP}) healthy — no latch"
      ACTION="pass"
    fi
  elif gt_float "$USD_TOTAL" "$DBW_LOW_USD"; then
    log "$TS HOLD balance=USD ${USD_TOTAL} below-clear (${DBW_CLEAR_USD}) above-low (${DBW_LOW_USD}) — latch untouched (hysteresis)"
    ACTION="hold"
  else
    # at/below LOW (boundary inclusive: == LOW latches) → SET
    if latch set --primary deepseek --reason low_balance --source poller \
      --notice "DeepSeek balance low|Balance USD ${USD_TOTAL} is at/below \$${DBW_LOW_USD}. Top up: https://platform.deepseek.com/top_up"; then
      latch ledger --event poller-set --provider deepseek --detail "balance USD ${USD_TOTAL} <= low ${DBW_LOW_USD}"
      log "$TS SET balance=USD ${USD_TOTAL} at/below-low (${DBW_LOW_USD}) — exhaustion latch SET (fail-closed toward hop legs)"
      ACTION="set"
    else
      log "$TS LATCH-SET-FAILED balance=USD ${USD_TOTAL} at/below-low — durable latch write failed; no latch (sessions unprotected until 402 markers)"
      ALERTED=1
    fi
  fi
else
  case "$CODE" in
    401|403)
      log "$TS SKIP http=${CODE} (deepseek auth rejected — NOT a balance condition; never latch on auth failure, s6)"
      ;;
    000)
      log "$TS FAIL http=timeout/connect (max-time ${MAX_TIME_S}s) — balance unknown (defer + escalate)"
      ALERTED=1
      ;;
    429|5*)
      log "$TS DEFER http=${CODE} (provider overload/error) — balance unknown"
      ALERTED=1
      ;;
    *)
      log "$TS WARN http=${CODE} unexpected (no action)"
      ;;
  esac
fi

# ── consecutive-failure escalation (liveness) ───────────────────────────────
if [ "$ALERTED" -eq 1 ]; then
  local_n="$(cat "$CONSEC_FAIL_FILE" 2>/dev/null || echo 0)"
  local_n=$((local_n + 1))
  printf '%s\n' "$local_n" > "$CONSEC_FAIL_FILE"
  if [ "$local_n" -ge 3 ]; then
    log "$TS ESCALATE ${local_n} consecutive degraded runs — balance state unknown for ${local_n} intervals; check https://status.deepseek.com; latch: $(python3 "$LATCH_PY" status 2>/dev/null | tr '\n' ' ' | head -c 160)"
  fi
else
  rm -f "$CONSEC_FAIL_FILE"
fi

# ── openrouter hop-leg report (s6: /auth/key is the zero-token leg probe) ───
# Own consecutive-failure counter: OR degradation must NOT reset the deepseek
# "balance unknown" streak nor share its escalation semantics (a dead OR
# endpoint is a leg problem, not a primary-balance verdict).
OR_CONSEC_FILE="${DBW_CONSEC_FILE:-/tmp/deepseek-balance-watch.consec}.or"
OR_KEY="$(resolve_key OPENROUTER_API_KEY "${DBW_OR_KEY:-}")"
if [ -n "$OR_KEY" ]; then
  OR_RAW="$(dbw_curl "https://openrouter.ai/api/v1/auth/key" -H "Authorization: Bearer $OR_KEY")"
  probe_triple "$OR_RAW"
  OR_DEGRADED=0
  if [ "$CODE" = "200" ]; then
    OR_LIM="$(parse_openrouter_limit "$BODY")"
    if [ -z "$OR_LIM" ]; then
      log "$TS WARN openrouter http=200 body-unexpected (schema drift — no action)"
    elif gt_float "$DBW_OR_MIN_USD" "$OR_LIM"; then
      log "$TS ALERT openrouter limit_remaining=USD ${OR_LIM} below ${DBW_OR_MIN_USD} — hop leg low (credits: https://openrouter.ai/settings/credits)"
      ALERTED=1
    else
      log "$TS PASS openrouter limit_remaining=USD ${OR_LIM} — hop leg healthy"
    fi
  else
    log "$TS ${CODE/000/FAIL} openrouter http=${CODE} (auth or network) — leg not probeable this run"
    case "$CODE" in 401|403) ;; *) OR_DEGRADED=1 ;; esac
  fi
  # OR liveness: 3 consecutive non-200 (non-auth) OR probes escalate; a
  # healthy OR probe resets the OR counter. Never touches the deepseek counter.
  if [ "$OR_DEGRADED" -eq 1 ]; then
    or_n="$(cat "$OR_CONSEC_FILE" 2>/dev/null || echo 0)"
    or_n=$((or_n + 1))
    printf '%s\n' "$or_n" > "$OR_CONSEC_FILE"
    if [ "$or_n" -ge 3 ]; then
      log "$TS ESCALATE-OR ${or_n} consecutive degraded openrouter probes — hop leg unprobeable; verify the key at https://openrouter.ai/settings/keys"
    fi
    ALERTED=1
  else
    # healthy probe resets the OR streak
    rm -f "$OR_CONSEC_FILE"
  fi
else
  # keyless skip: a skipped leg must never carry a stale liveness streak
  rm -f "$OR_CONSEC_FILE"
fi

if [ "$ALERTED" -eq 1 ]; then exit 1; fi
exit 0
