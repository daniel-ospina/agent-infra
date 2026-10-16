#!/usr/bin/env bash
# orch-send.sh — the ONLY safe way to dispatch a lane order from the orchestrator.
#
# Why this exists (2026-10-11, four incidents in one night):
#   - an order was sent to a DMeer lane (different repo/product)
#   - an order was sent to THE ORCHESTRATOR ITSELF (workspace NAMED "Packs + Extractor")
#   - an order was sent to a UUID that does not exist
#   - an empty/whitespace pane footer made a NEGATIVE guard (case ... "not found"|"") FAIL OPEN
#
# RULE: a NEGATIVE list fails open. Require a POSITIVE match instead — the pane footer must
# contain a known-good repo path. Anything else is refused, including an unreadable pane.
#
# Usage: orch-send.sh <workspace-uuid> <label> <message|@file>
#   The message may be given inline, or as "@/path/to/file" to read it from a file.
#   USE A FILE whenever the text contains quotes, parentheses, backticks, or words the
#   evidence-gate extension pattern-matches (merge/commit/git fetch/gh pr ...). Inlining
#   those has twice bitten this session: once by interception, once by shell mangling.
#
#   ⛔ THE EXIT CODE IS NOT A DELIVERY SIGNAL (#1187). `cmux send` returns OK while
#   delivering only a PREFIX of a payload: measured 2026-09-29, a 1,962-byte message
#   arrived as its first sentence and a 1,404-byte one as its first numbered item,
#   both with OK, while a 5,464-byte message arrived intact — so size does not predict
#   delivery, and neither does a turn having started (a truncated prefix starts one).
#   The TAIL is what a prefix truncation loses, so CONSUMED is now reported only when
#   the payload's tail marker is on the recipient's pane (or in its session transcript).
#   Anything else is SENT BUT NOT VERIFIED with a non-zero exit. The check lives in
#   scripts/lib/cmux_payload.py so every caller uses one rule.
set -uo pipefail

W="${1:-}"; LABEL="${2:-?}"; MSG="${3:-}"
[ -n "$W" ] && [ -n "$MSG" ] || { echo "usage: orch-send.sh <uuid> <label> <msg|@file>"; exit 2; }
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$MSG" in
  @*)
    F="${MSG#@}"
    [ -r "$F" ] || { echo "$LABEL: REFUSED — message file not readable: $F"; exit 2; }
    MSG="$(cat "$F")"
    ;;
esac

# Positive allowlist of legitimate lane checkouts.
# Accept BOTH forms. The pane footer prints an ABSOLUTE path
# (/Users/<user>/Documents/GitHub/tortoise) while a tilde form was the only thing
# matched here — so the pane source silently never matched and every dispatch
# depended on the (stale) generated map. Measured 2026-10-13: 3 of 4 lanes refused.
ALLOW_RE='(~/|/Users/[^/]+/)Documents/GitHub/(tortoise|agent-infra)'

read_footer() {
  # 24 lines, not 8: a lane's pane often ends with several `[session-checks]` noise lines plus the
  # status bar, which can push the `~/Documents/GitHub/<repo>` line out of a small window and cause
  # a FALSE refusal on a legitimate target (observed 2026-10-11 on ci-substrate).
  cmux read-screen --workspace "$W" --lines 24 2>&1
}

# `cmux read-screen` is INTERMITTENTLY EMPTY on a live pane (observed 2026-10-11: two consecutive
# empty reads on ci-substrate, a lane that was demonstrably working). An empty read is NOT evidence
# of a wrong target, so retry before concluding anything. Fail-closed still applies AFTER the retries:
# a wrong-lane dispatch is worse than a delayed one.
FOOT=""
for _try in 1 2 3 4; do
  FOOT="$(read_footer)"
  grep -qE "$ALLOW_RE" <<<"$FOOT" && break
  sleep 6
done

REPO=""
_via_map=""
_via_live=""

if grep -qE "$ALLOW_RE" <<<"$FOOT"; then
  REPO="$(printf '%s' "$FOOT" | grep -oE "$ALLOW_RE" | head -1)"
  # Orchestrator self-check: its footer carries this session's unique spend + RSS signature.
  case "$FOOT" in
    *'$9.893'*|*'R1146M'*) echo "$LABEL: REFUSED — that is the ORCHESTRATOR ($REPO)"; exit 4;;
  esac
  # DMeer guard.
  case "$FOOT" in *DMeer*) echo "$LABEL: REFUSED — DMeer, OUT OF BOUNDS"; exit 5;; esac
else
  # ⛔ SECOND POSITIVE SOURCE: the GENERATED lane map.
  # Why: under heavy load the pane redraws PARTIALLY — the repo footer line is absent while
  # `[session-checks]` noise and the status bar are present. Observed 2026-10-11 on ci-substrate:
  # a byte-identical noise-only footer on every read, so the pane check could NEVER be satisfied.
  # A guard that can never open is not a gate. The map is GENERATED from `cmux workspace list`
  # (state/LANE-MAP-TRUTH.md), so it is authoritative for "this UUID is a real lane named X" —
  # unlike a RECALLED list, which is what caused the DMeer and self-dispatch incidents.
  MAP="$HOME/.pi/agent/state/LANE-MAP-TRUTH.md"
  if [ -r "$MAP" ]; then
    ROW="$(grep -F "$W" "$MAP" 2>/dev/null | head -1)"
    if [ -n "$ROW" ]; then
      case "$ROW" in
        *DMeer*)        echo "$LABEL: REFUSED — DMeer lane (map row: $ROW)"; exit 5;;
        *ORCHESTRATOR*) echo "$LABEL: REFUSED — the orchestrator (map row: $ROW)"; exit 4;;
      esac
      _via_map=1
      echo "$LABEL: target OK via GENERATED MAP (pane unreadable under load): $(printf '%s' "$ROW" | cut -c1-100)"
    fi
  fi
fi

# ⛔ THIRD SOURCE — LIVE, and authoritative. The generated map is a DERIVED SNAPSHOT: it was
# written 11 Oct 23:09 and the fleet was rebuilt on 12 Oct, so it was missing three live lanes
# (6 Durability core, 2b Extractor, 3 Onboarding) and dispatch REFUSED on all of them — a stale
# flag recording a past state, never revalidated. cmux's own `current_directory` is the source
# that map is derived FROM, so read it LIVE instead of trusting a snapshot. Same denylist.
if [ -z "$_via_map" ] && [ -z "$REPO" ]; then
  _live="$(cmux workspace list --json --id-format both 2>/dev/null | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ws = d if isinstance(d, list) else d.get("workspaces", [])
wid = sys.argv[1]
for w in ws:
    if (w.get("id") or w.get("uuid") or "") == wid:
        print(w.get("current_directory") or "")
        print(w.get("title") or w.get("name") or "")
        break
' "$W" 2>/dev/null)"
  if [ -n "$_live" ]; then
    L_DIR="$(printf '%s\n' "$_live" | sed -n 1p)"
    L_TITLE="$(printf '%s\n' "$_live" | sed -n 2p)"
    case "$L_TITLE" in
      *DMeer*)        echo "$LABEL: REFUSED — DMeer lane (live cmux title: $L_TITLE)"; exit 5;;
      *ORCHESTRATOR*) echo "$LABEL: REFUSED — the orchestrator (live cmux title: $L_TITLE)"; exit 4;;
    esac
    case "$L_DIR" in
      *Documents/GitHub/tortoise*|*Documents/GitHub/agent-infra*)
        REPO="$L_DIR"; _via_live=1
        echo "$LABEL: target OK via LIVE cmux current_directory ($L_DIR)" ;;
    esac
  fi
fi

if [ -z "$_via_map" ] && [ -z "$_via_live" ] && [ -z "$REPO" ]; then
  # POSITIVE requirement not met on BOTH sources -> refuse. Covers the wrong-repo case AND the
  # unreadable-pane case with no separate empty-string branch to get wrong.
  echo "$LABEL: REFUSED — neither the pane nor the generated map confirms an allowed repo."
  echo "$LABEL:   footer was: $(printf '%s' "$FOOT" | tr '\n' ' ' | tail -c 160)"
  echo "$LABEL:   NOT dispatched. Re-read the pane; never guess the target."
  exit 3
fi

if [ -z "$_via_map" ]; then echo "$LABEL: target OK ($REPO)"; fi

# ── SEND + VERIFY THE TAIL (#1187) ──────────────────────────────────────────
# The helper sends the payload, submits it with a terminating Enter, then polls
# the pane (and the lane's session transcript as a second source) for the payload's
# TAIL. A prefix truncation loses the tail, so absence of the tail is the signal.
# A non-zero helper exit (unreadable pane, cmux failure, no tail) is UNVERIFIED
# and MUST NOT be reported as a delivered order. NOTE: a message that arrives in
# the ORCHESTRATOR'S OWN pane would also verify — the self-check above runs FIRST.
cmux_payload_verdict="$(/usr/bin/python3 "$SCRIPTS/lib/cmux_payload.py" verify \
      --workspace "$W" --text="$MSG" --screen-lines 200 \
      --timeout "${ORCH_SEND_VERIFY_TIMEOUT:-30}" 2>/dev/null)"
case "$cmux_payload_verdict" in
  VERIFIED)
    echo "$LABEL: CONSUMED (payload tail verified on the pane)"
    exit 0 ;;
  *)
    echo "$LABEL: SENT BUT NOT VERIFIED — the payload TAIL is not on the pane."
    echo "$LABEL:   cmux send returns OK while delivering only a PREFIX under load (#1187),";
    echo "$LABEL:   so this send is NOT recorded as delivered. Re-read the pane and re-send;"
    echo "$LABEL:   for a long body, write it to a file and send a short one-line pointer."
    exit 6 ;;
esac
