#!/usr/bin/env bash
# ci_runner_gate.sh — route CI to GitHub-hosted runners, fall back to the local pool
# when GitHub-hosted is unhealthy, and notify on every transition.
#
# WHY THIS EXISTS
#   The self-hosted pool (`pi-runner-vm-*`) originally advertised the `ubuntu-latest`
#   label, so the 77 `runs-on: ubuntu-latest` jobs in daniel-ospina/tortoise raced
#   between GitHub-hosted and this Mac — and jobs landing here compete with the pi
#   fleet and the Tortoise graph (a local pytest run crashed FalkorDB at
#   src/reply.rs:655, 178 restarts, 2026-10-12).
#
#   The pool's CUSTOM label is now `self-hosted-arm64` (distinct), so `ubuntu-latest`
#   resolves to GitHub-hosted ONLY and CI runs on GitHub "where possible". This script
#   is the FALLBACK: when GitHub-hosted is unhealthy it re-adds `ubuntu-latest` to the
#   pool so the same workflows can land locally instead of queueing forever.
#
# WHY IT RUNS OUTSIDE ACTIONS
#   If GitHub Actions itself is degraded, anything scheduled INSIDE Actions is dead
#   exactly when it is needed. This runs from launchd on the Mac. It only helps for
#   GitHub-hosted CAPACITY/queue problems — a full Actions control-plane outage also
#   disables self-hosted job dispatch (GitHub's scheduler is the same one).
#
# USAGE
#   ci_runner_gate.sh            # evaluate + act + notify
#   ci_runner_gate.sh --dry-run  # evaluate and report, change nothing
#   ci_runner_gate.sh --status   # print current mode, exit 0
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure (fail-closed: changes nothing)
set -uo pipefail

REPO="${CI_GATE_REPO:-daniel-ospina/tortoise}"
STATE_DIR="${CI_GATE_STATE_DIR:-$HOME/.pi/agent/state}"
STATE_FILE="$STATE_DIR/ci-runner-gate.state"
LOG_FILE="$STATE_DIR/ci-runner-gate.log"
QUEUE_THRESHOLD="${CI_GATE_QUEUE_THRESHOLD:-60}"   # queued runs = GitHub-hosted backlog
# The custom label that makes a job land on the LOCAL pool.
FALLBACK_LABEL="ubuntu-latest"
# The pool's own distinct label (always present).
POOL_LABEL="self-hosted-arm64"

DRY=0; STATUS_ONLY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --status)  STATUS_ONLY=1 ;;
    *) echo "usage: $0 [--dry-run|--status]" >&2; exit 1 ;;
  esac
done

mkdir -p "$STATE_DIR"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2; }

need() { command -v "$1" >/dev/null 2>&1 || { log "FATAL: '$1' not on PATH"; exit 2; }; }
need gh; need curl; need python3

# ── health probe ────────────────────────────────────────────────────────────────
# Unhealthy if: the Actions component is not operational, OR an incident mentions
# Actions, OR the queued backlog exceeds the threshold. The component alone is NOT
# sufficient — a live Actions incident has been observed with the component still
# reading "operational".
probe_status() {
  curl -fsS --max-time 20 https://www.githubstatus.com/api/v2/summary.json 2>/dev/null || return 1
}

evaluate() {
  local summary queued comp incident
  summary="$(probe_status)" || { log "status probe FAILED (network/status api)"; return 2; }

  read -r comp incident <<<"$(printf '%s' "$summary" | python3 -c '
import json,sys
d=json.load(sys.stdin)
comp="?"
for c in d.get("components",[]):
    if c.get("name")=="Actions":
        comp=c.get("status","?")
inc=[i for i in d.get("incidents",[]) if "actions" in (i.get("name","")+i.get("impact","")).lower()]
print(comp, len(inc))
' 2>/dev/null)" || return 2

  queued="$(gh api "repos/$REPO/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null)" \
    || { log "queue probe FAILED (gh api)"; return 2; }

  log "probe: actions_component=$comp actions_incidents=$incident queued=$queued threshold=$QUEUE_THRESHOLD"

  if [ "$comp" != "operational" ] || [ "${incident:-0}" != "0" ] || [ "${queued:-0}" -ge "$QUEUE_THRESHOLD" ]; then
    return 1   # unhealthy -> prefer local
  fi
  return 0     # healthy   -> prefer GitHub
}

# ── label control ───────────────────────────────────────────────────────────────
runner_ids() { gh api "repos/$REPO/actions/runners" --jq '.runners[].id' 2>/dev/null; }

set_labels() { # $1 = json array body
  local body="$1" id ok=0 fail=0
  for id in $(runner_ids); do
    if printf '%s' "$body" | gh api -X PUT "repos/$REPO/actions/runners/$id/labels" --input - >/dev/null 2>&1; then
      ok=$((ok+1))
    else
      fail=$((fail+1))
    fi
  done
  log "set_labels ok=$ok fail=$fail body=$body"
  [ "$fail" -eq 0 ]
}

fallback_on()  { set_labels "{\"labels\":[\"$POOL_LABEL\",\"$FALLBACK_LABEL\"]}"; }
fallback_off() { set_labels "{\"labels\":[\"$POOL_LABEL\"]}"; }

current_mode() {  # github | local | unknown
  local n
  n="$(gh api "repos/$REPO/actions/runners" \
        --jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>&1)" || { log "gh api failed: ${n:0:300}"; return 1; }
  case "$n" in ''|*[!0-9]*) log "gh api returned non-numeric: ${n:0:300}"; return 1 ;; esac
  if [ "${n:-0}" -gt 0 ]; then echo local; else echo github; fi
}

# ── notify ──────────────────────────────────────────────────────────────────────
# NO external service (Slack is deprecated — it was a maintenance burden). Two
# transports, both already in the fleet, neither needs a credential we do not have:
#   1. the orchestrator inbox  — durable, append-only, read by the fleet (always works)
#   2. the cmux orchestrator lane — immediate, where the owner actually is (best-effort)
ORCH_WS="${CI_GATE_ORCH_WS:-C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD}"   # ORCHESTRATOR (never dispatch here)

notify() { # $1 = text
  local text="$1"
  # 1. durable local inbox — no dependencies, cannot fail silently.
  printf '[%s] [ci-runner-gate] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$text" \
    >> "$STATE_DIR/orchestrator-inbox.log"
  log "notified -> orchestrator-inbox.log"

  # 2. cmux — best effort. A message that is not delivered must NOT fail the gate.
  #    AGENTS.md: never a bare `cmux send`; confirm the artifact, and a queued
  #    (delivered-but-not-consumed) message still counts as delivered.
  if command -v cmux >/dev/null 2>&1 && [ -n "${ORCH_WS:-}" ]; then
    if cmux agent message "$ORCH_WS" --from ci-runner-gate "$text" >/dev/null 2>&1; then
      log "notified -> cmux orchestrator lane"
    else
      log "cmux notify unavailable (inbox record stands)"
    fi
  fi
  return 0
}

# ── main ────────────────────────────────────────────────────────────────────────
mode="$(current_mode)" || { log "cannot read runner labels"; exit 2; }
if [ "$STATUS_ONLY" = 1 ]; then echo "mode=$mode repo=$REPO"; exit 0; fi

evaluate; healthy=$?          # 0 = github, 1 = unhealthy, 2 = cannot measure
if [ "$healthy" = 2 ]; then
  log "cannot measure — FAIL-CLOSED, changing nothing (leaving mode=$mode)"
  exit 2
fi

if [ "$healthy" = 0 ]; then
  want="github"
  reason="GitHub Actions healthy (component operational, no Actions incident, queue < $QUEUE_THRESHOLD)"
else
  want="local"
  reason="GitHub-hosted UNHEALTHY — routed CI to the local pool"
fi

prev="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"

if [ "$DRY" = 1 ]; then
  echo "dry-run: mode=$mode want=$want prev=$prev reason=$reason"
  exit 0
fi

if [ "$mode" != "$want" ]; then
  if [ "$want" = local ]; then fallback_on || log "WARNING: some runners not relabeled"; else fallback_off || log "WARNING: some runners not relabeled"; fi
fi

# Notify only on TRANSITION into a new desired mode (dedupe by state file).
if [ "$prev" != "$want" ]; then
  notify ":rotating_light: CI runner gate: mode *${mode}* -> *${want}*. ${reason}. Repo: ${REPO}."
  printf '%s\n' "$want" > "$STATE_FILE"
  log "TRANSITION $prev -> $want"
else
  log "no change (mode=$mode want=$want)"
fi
exit 0
