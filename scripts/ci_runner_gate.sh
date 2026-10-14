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
#   ci_runner_gate.sh --status   # print current mode, exit 0 (2 when the pool read fails)
#
# EXIT: 0 ok · 1 usage · 2 could-not-measure / could-not-act (fail-closed: changes nothing)
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
  local summary queued comp incident parsed
  summary="$(probe_status)" || { log "status probe FAILED (network/status api)"; return 2; }

  parsed="$(printf '%s' "$summary" | python3 -c '
import json,sys
d=json.load(sys.stdin)
comp="?"
for c in d.get("components",[]):
    if c.get("name")=="Actions":
        comp=c.get("status","?")
inc=[i for i in d.get("incidents",[]) if "actions" in (i.get("name","")+i.get("impact","")).lower()]
print(comp, len(inc))
' 2>/dev/null)" || { log "status summary parse FAILED (python)"; return 2; }
  # ⛔ SHAPE-CHECK THE CAPTURED VALUE. `read -r a b <<<""` returns 0 for an empty here-string, so the
  # guard that used to hang off `read` could never fire: a json.load failure left comp="" — which
  # is NOT "operational", so the gate returned 1 (unhealthy) and ACTED on it, relabelling the pool
  # and routing CI onto this box. That is the opposite of what the header promises (`2
  # could-not-measure (fail-closed: changing nothing)`). It also catches python's `comp="?"`
  # fallback, so a githubstatus schema change is unreadable rather than "not operational".
  #
  # ⛔ `[:blank:]`, NOT `[:space:]` (review B1). The inline python prints `comp` and the incident
  # count SPACE-separated, so a status that is `null`/`""` yields `" 0"` — and `read`, which strips
  # leading IFS whitespace, turns that into `comp="0"`, not `""`. Admitting a newline let a status
  # containing one truncate the line so the incident field vanished. Neither is a readable summary.
  case "$parsed" in ''|*[!A-Za-z0-9_[:blank:]]*) log "status summary unreadable: ${parsed:0:120}"; return 2 ;; esac
  read -r comp incident <<<"$parsed"

  # ⛔ BOTH FIELDS MUST BE STRICTLY READABLE (review B1). `comp` was compared verbatim and
  # `incident` was never checked at all — `${incident:-0}` read an EMPTY count as "0 incidents", so
  # a summary whose second field did not parse reported HEALTHY while an Actions incident was live
  # (`fallback_off` would then relabel the pool off `ubuntu-latest` exactly when GitHub-hosted is
  # degraded). A component status outside GitHub's documented set — `None`, `""`, `"?"`, or any
  # future value — is a schema change, i.e. could-not-measure (2), never "unhealthy" (1): acting on
  # an unread status relabels the pool. Only the four non-operational statuses fall through to 1.
  # `comp` is checked FIRST: when the status is unreadable the space-separated print leaves the
  # incident field empty too, and naming the status is the more useful of the two reasons.
  case "$comp" in
    operational|degraded_performance|partial_outage|major_outage|under_maintenance) ;;
    *) log "actions component UNREADABLE ('${comp}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac
  case "$incident" in '' | *[!0-9]*) log "incident count UNREADABLE ('${incident}') — FAIL-CLOSED, changing nothing"; return 2 ;; esac
  queued="$(gh api "repos/$REPO/actions/runs?status=queued&per_page=1" --jq '.total_count' 2>/dev/null)" \
    || { log "queue probe FAILED (gh api)"; return 2; }

  log "probe: actions_component=$comp actions_incidents=$incident queued=$queued threshold=$QUEUE_THRESHOLD"

  # ⛔ SHAPE-CHECK THE COUNT TOO (agent-infra#1704). `comp` was shape-checked; `queued` was not, so
  # a successful probe that yielded `null`/empty (a schema change, a proxy body, a truncated read)
  # made `[ "$queued" -ge "$QUEUE_THRESHOLD" ]` ERROR (status 2) — and the `||` chain reads a failed
  # test as FALSE, i.e. HEALTHY. "Healthy" means want=github -> `fallback_off`, which RELABELS the
  # local pool: a state change taken on a value that was never read. A count that is not a
  # non-negative integer is unreadable, so this is could-not-measure (return 2) — never healthy.
  case "$queued" in
    '' | *[!0-9]*) log "queued count UNREADABLE ('${queued}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac

  # ⛔ THE THRESHOLD IS THE OTHER OPERAND OF THE SAME NUMERIC TEST (review D1), so an unreadable
  # value makes `[ "$queued" -ge "$QUEUE_THRESHOLD" ]` ERROR — and the `||` chain reads that as
  # false, i.e. HEALTHY — relabelling the pool, advancing the state file and notifying on a value
  # that was never read. The launchd job never sets CI_GATE_QUEUE_THRESHOLD (the plist carries only
  # PATH/HOME), so this is reachable from an env-overriding caller rather than from the schedule;
  # the read is refused either way.
  #
  # ⛔ DIGITS ALONE IS NOT THE PREDICATE `[ -ge ]` NEEDS (review B2-2). A digit string longer than
  # `intmax` passes a character-class guard and STILL errors the comparison, which the `||` chain
  # reads as false — the same fail-open one step later (measured: a 26-digit threshold relabelled
  # the pool, advanced the state file and notified, exit 0). So the bound is the number of digits,
  # on BOTH operands: 9 digits cannot exceed intmax on any platform bash's `[` supports, and no real
  # queued-run count approaches it. Anything larger is out of range, not a measurement.
  case "$queued" in ??????????*) log "queued count OUT OF RANGE ('${queued}') — FAIL-CLOSED, changing nothing"; return 2 ;; esac
  case "$QUEUE_THRESHOLD" in
    '' | *[!0-9]*) log "queue threshold UNREADABLE ('${QUEUE_THRESHOLD}') — FAIL-CLOSED, changing nothing"; return 2 ;;
    ??????????*) log "queue threshold OUT OF RANGE ('${QUEUE_THRESHOLD}') — FAIL-CLOSED, changing nothing"; return 2 ;;
  esac

  if [ "$comp" != "operational" ] || [ "$incident" != "0" ] || [ "$queued" -ge "$QUEUE_THRESHOLD" ]; then
    return 1   # unhealthy -> prefer local
  fi
  return 0     # healthy   -> prefer GitHub
}

# ── label control ───────────────────────────────────────────────────────────────
# ⛔ --paginate is REQUIRED: `gh api` returns at most 30 runners per page, so a pool larger than
# that was relabelled only in part, and `set_labels` reported ok=N over a truncated set.
runner_ids() { gh api --paginate "repos/$REPO/actions/runners" --jq '.runners[].id'; }

# set_labels <json-array body> — relabel every runner in the pool.
#
# ⛔ THE ENUMERATION'S FAILURE MUST SURVIVE TO THE RETURN VALUE (agent-infra#1704). The shape
# `for id in $(runner_ids)` DISCARDED the command-substitution status, so a failed `gh api` iterated
# zero ids, left ok=0 fail=0, and `[ "$fail" -eq 0 ]` reported SUCCESS. `main` then wrote the new
# mode to the state file and sent a TRANSITION notification — as if the pool had been relabelled.
# So the read is captured FIRST: a non-zero status is a named failure and NOTHING is relabelled,
# and a payload that is not a list of ids (gh's error text, an API error body) is refused the same
# way rather than iterated as a runner id. "The pool has zero runners" is still a success — that is
# a readable zero, not a failed read.
set_labels() { # $1 = json array body
  local body="$1" id ok=0 fail=0 ids
  if ! ids="$(runner_ids 2>&1)"; then
    log "WARNING: runner enumeration FAILED — no labels changed; ${ids:0:300}"
    return 1
  fi
  case "$ids" in
    *[!0-9[:space:]]*)
      log "WARNING: runner enumeration unreadable — no labels changed; ${ids:0:300}"
      return 1 ;;
  esac
  for id in $ids; do
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
  # ⛔ PER-PAGE COUNTS, SUMMED. Without --paginate the read stops at the default 30 runners, so a
  # fallback-labelled runner that lands on a later page is invisible and the mode resolves `github`
  # while the fallback is still attached — the gate then leaves the stale fallback in place and
  # reports the wrong mode. `--jq` cannot aggregate across pages (a `length` emits one number PER
  # PAGE, which the numeric guard below would reject rather than sum), and gh 2.97 refuses `--slurp`
  # together with `--jq` (verified: "the `--slurp` option is not supported with `--jq`"), so the
  # per-page counts are summed here instead. The failure signal is unchanged: a failed or
  # non-numeric read still returns 1 (unknown), never a guessed mode.
  local n pages
  pages="$(gh api --paginate "repos/$REPO/actions/runners" \
        --jq "[.runners[] | select([.labels[].name] | index(\"$FALLBACK_LABEL\"))] | length" 2>&1)" || { log "gh api failed: ${pages:0:300}"; return 1; }
  # ⛔ SHAPE-CHECK, AND REQUIRE A DIGIT (review B2-1). `[:space:]` alone admits a read that contains
  # NO number at all (a blank/whitespace body from a proxy or a gh change) — the `awk` reduction then
  # sums nothing to 0 and the mode resolves `github` at exit 0, i.e. a verdict AND a recorded
  # transition from a read with no value in it. The line below it promises the opposite ("a failed or
  # non-numeric read still returns 1 (unknown), never a guessed mode"). The `awk` SUBSTITUTION's
  # status is captured too: a broken/absent `awk` left `${n:-0}` to read as `0`.
  case "$pages" in ''|*[!0-9[:space:]]*) log "gh api returned non-numeric: ${pages:0:300}"; return 1 ;; esac
  case "$pages" in *[0-9]*) : ;; *) log "gh api returned NO COUNT: ${pages:0:300}"; return 1 ;; esac
  n="$(printf '%s\n' "$pages" | awk '{s+=$1} END{printf "%d", s+0}')" || { log "runner-count reduction FAILED (awk)"; return 1; }
  case "$n" in ''|*[!0-9]*) log "runner-count reduction unreadable: '${n}'"; return 1 ;; esac
  if [ "$n" -gt 0 ]; then echo local; else echo github; fi
}

# ── notify ──────────────────────────────────────────────────────────────────────
# NO external service (Slack is deprecated — it was a maintenance burden). Two
# transports, both already in the fleet, neither needs a credential we do not have:
#   1. the orchestrator inbox  — durable, append-only, read by the fleet (always works)
#   2. the cmux orchestrator lane — immediate, where the owner actually is (best-effort)
ORCH_WS="${CI_GATE_ORCH_WS-C2C97E96-0CBC-4DFE-BC91-FEF44F09B5BD}"   # ORCHESTRATOR (never dispatch here)
# ⛔ `${VAR-…}`, NOT `${VAR:-…}` (review E1): with `:-` an explicitly EMPTY value is replaced by the
# default, so `CI_GATE_ORCH_WS=""` — the obvious way to switch the cmux leg off, and what the test
# suite sets to keep the leg out of the picture — actually SENT messages to the live orchestrator
# lane. Empty now means disabled.

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

# ⛔ RE-CONVERGE UNTIL THE TRANSITION IS RECORDED (review B2-3). `mode != want` is a cheap
# approximation of "the pool matches the desired labels", and it is not equivalent: a PARTIAL relabel
# (one PUT failed) leaves one runner labelled, so the next pass reads `mode == want` and would skip
# the relabel entirely — recording the transition while the un-relabelled runner is never retried
# and never mentioned. The state file records convergence, so its absence is the trigger to converge:
# `prev != want` re-applies the (idempotent) labels until the transition is actually recorded.
if [ "$mode" != "$want" ] || [ "$prev" != "$want" ]; then
  relabel_ok=1
  if [ "$want" = local ]; then fallback_on || relabel_ok=0; else fallback_off || relabel_ok=0; fi
  # ⛔ DO NOT RECORD A TRANSITION THAT DID NOT HAPPEN (agent-infra#1704). The old code logged a
  # WARNING and CONTINUED, so a failed enumeration still wrote the new mode to $STATE_FILE and sent
  # the transition notification — a state file and an alert claiming the pool had been relabelled.
  # Stop here instead: mode not advanced, nothing notified, fail-closed.
  if [ "$relabel_ok" -ne 1 ]; then
    log "relabel FAILED — mode NOT advanced (mode=$mode want=$want prev=$prev), state file unchanged"
    exit 2
  fi
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
