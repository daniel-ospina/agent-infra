#!/usr/bin/env bash
# provider-latency-tripwire.sh — hourly probe of api.deepseek.com; files a
# deduped GitHub issue when per-call latency regresses.
#
# Postmortem driver (#413, #424): on 2026-09-02/03 deepseek-v4-flash per-call
# latency regressed 4-8s → 30-70s (session-log medians) with NO local cause; a
# provider-side incident that cleared ~23:11Z on Sep 3. This tripwire exists so
# the next incident is detected and DATED within ~1 hour instead of being felt
# by a user. Direct probe baseline (post-incident): 1-2s small/cold/14k-token,
# 99.8% prefix-cache hit on repeat.
#
# Canonical script: agent-infra/scripts/checkout-hygiene/provider-latency-tripwire.sh
# (symlinked to ~/.pi/agent/scripts/checkout-hygiene/ by pi-bootstrap/setup.sh;
# launched hourly by com.eldato.provider-latency-tripwire plist, rendered by
# scripts/install-launchd.sh #304).
#
# Usage:
#   provider-latency-tripwire.sh [--dry-run]
#     --dry-run   print the alert that WOULD be filed; never calls gh.
#   Exit 0 = healthy (or SKIP — auth missing); 1 = FAIL (alert filed unless
#   --dry-run); 2 = usage.
#
# Env overrides (tests + tuning):
#   PLT_THRESHOLD_S   fail threshold, wall seconds (default 15)
#   PLT_MAX_TIME_S    curl max-time (default 35 — a hung provider = FAIL via
#                     timeout rather than an infinite block)
#   PLT_REPO          github slug for alerts (default daniel-ospina/agent-infra)
#   PLT_LOG           rolling one-line-per-run log (default /tmp/provider-latency-tripwire.log)
#   PLT_CURL_OUT      if SET (even empty), used as the probe output instead of
#                     calling curl (unit-test seam; must end with two lines:
#                     http_code then time_total, mirroring curl -w — empty =
#                     simulated curl failure/timeout)
#   PLT_KEY           api key override (default: resolve from ~/pi-keys.env or
#                     ~/.pi/agent/models.json literal)
#   GH_BIN            gh binary (default gh; stubbed in tests)

set -euo pipefail

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
  esac
done

THRESHOLD_S="${PLT_THRESHOLD_S:-15}"
MAX_TIME_S="${PLT_MAX_TIME_S:-35}"
REPO="${PLT_REPO:-daniel-ospina/agent-infra}"
LOG="${PLT_LOG:-/tmp/provider-latency-tripwire.log}"
GH_BIN="${GH_BIN:-gh}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

# ── api key resolution (launchd env does not inherit the shell profile) ──────
resolve_key() {
  local key=""
  if [ -n "${PLT_KEY:-}" ]; then
    printf '%s' "$PLT_KEY"; return
  fi
  if [ -f "$HOME/pi-keys.env" ]; then
    key="$(bash -c 'source "$HOME/pi-keys.env" >/dev/null 2>&1; printf "%s" "${DEEPSEEK_API_KEY:-}"' 2>/dev/null || true)"
  fi
  if [ -z "$key" ]; then
    # models.json may hold a literal key or an env-ref ($VAR); only literals
    # are usable here (env-refs need a shell that sources pi-keys.env anyway).
    local ref
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

# ── probe: real curl, or the PLT_CURL_OUT test seam ──────────────────────────
run_probe() {
  local out code time_total
  if [ -n "${PLT_CURL_OUT+x}" ]; then
    out="$PLT_CURL_OUT"
  else
    local url="https://api.deepseek.com/chat/completions"
    # shellcheck disable=SC2016
    local payload='{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Reply with the single word: OK"}],"max_tokens":5}'
    out="$(curl -sS -m "$MAX_TIME_S" \
      -w '\n%{http_code}\n%{time_total}' \
      -H "Authorization: Bearer $KEY" \
      -H "Content-Type: application/json" \
      -d "$payload" "$url" 2>/dev/null || true)"
  fi
  code="$(printf '%s\n' "$out" | tail -2 | head -1)"
  time_total="$(printf '%s\n' "$out" | tail -1)"
  if [ -z "$code" ] || ! printf '%s' "$code" | grep -qE '^[0-9]{3}$'; then
    code="000"; time_total=""   # curl failed outright (timeout / DNS / connect)
  fi
  printf '%s %s' "$code" "$time_total"
}

gt_float() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

# ── deduped alert (mirrors hub-state-check --gh-report, #1484) ───────────────
file_alert() { # <latency> <detail>
  local latency="$1" detail="$2"
  local title="provider-latency: api.deepseek.com FAIL (${latency}s, threshold ${THRESHOLD_S}s)"
  local body="Provider-latency tripwire FAILED at $TS.

- probe: deepseek-v4-flash chat/completions (5-token reply cap)
- measured: ${latency}s (threshold ${THRESHOLD_S}s)
- detail: $detail
- context: the 2026-09-02/03 regression (30-70s/call) was a provider-side
  incident (#413); this tripwire dates the next one. Direct-probe healthy
  baseline: 1-2s. Check https://status.deepseek.com and the local time series
  in /tmp/provider-latency-tripwire.log."

  if [ "$DRY_RUN" -eq 1 ]; then
    log "$TS [dry-run] would file: $title"
    return 0
  fi
  # Dedup: one OPEN provider-latency issue → comment; else create.
  local existing
  existing="$("$GH_BIN" issue list --repo "$REPO" --state open --search "provider-latency in:title" --json number --jq '.[0].number' 2>/dev/null || true)"
  existing="$(printf '%s' "$existing" | tr -d '[]')"
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    "$GH_BIN" issue comment --repo "$REPO" "$existing" --body "$body" >/dev/null 2>&1 \
      && log "$TS → commented on existing provider-latency issue #$existing ($REPO)" \
      || log "$TS ⚠️ gh comment failed for $REPO (issue #$existing)" >&2
  else
    local url
    url="$("$GH_BIN" issue create --repo "$REPO" --title "$title" --body "$body" 2>/dev/null || true)"
    if [ -n "$url" ]; then log "$TS → opened provider-latency issue: $url"; else log "$TS ⚠️ gh issue create failed for $REPO" >&2; fi
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
KEY="$(resolve_key)"
if [ -z "$KEY" ]; then
  log "$TS SKIP no api key (DEEPSEEK_API_KEY) — probe skipped (not a latency condition)"
  exit 0
fi

read -r HTTP LATENCY <<<"$(run_probe)"

case "$HTTP" in
  200)
    if [ -z "$LATENCY" ] || ! gt_float "$LATENCY" "$THRESHOLD_S"; then
      log "$TS PASS http=200 wall=${LATENCY:-?}s threshold=${THRESHOLD_S}s"
      exit 0
    fi
    log "$TS FAIL http=200 wall=${LATENCY}s threshold=${THRESHOLD_S}s"
    file_alert "$LATENCY" "http 200 but wall time ${LATENCY}s > ${THRESHOLD_S}s"
    exit 1
    ;;
  401|403)
    log "$TS SKIP http=${HTTP} (auth rejected — not a latency condition)"
    exit 0
    ;;
  000)
    log "$TS FAIL http=timeout (curl max-time ${MAX_TIME_S}s exceeded or connect failed)"
    file_alert ">${MAX_TIME_S}" "curl timeout/connect failure (max-time ${MAX_TIME_S}s)"
    exit 1
    ;;
  429|5*)
    log "$TS FAIL http=${HTTP} wall=${LATENCY:-?}s (provider overload/error)"
    file_alert "${LATENCY:-unknown}" "http ${HTTP}"
    exit 1
    ;;
  *)
    log "$TS WARN http=${HTTP} wall=${LATENCY:-?}s (unexpected http — logged, no alert)"
    exit 0
    ;;
esac
