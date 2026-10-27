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
set -uo pipefail

W="${1:-}"; LABEL="${2:-?}"; MSG="${3:-}"
[ -n "$W" ] && [ -n "$MSG" ] || { echo "usage: orch-send.sh <uuid> <label> <msg|@file>"; exit 2; }

case "$MSG" in
  @*)
    F="${MSG#@}"
    [ -r "$F" ] || { echo "$LABEL: REFUSED — message file not readable: $F"; exit 2; }
    MSG="$(cat "$F")"
    ;;
   *) F="" ;;
 esac

# ── THE BRIEF GATE (agent-infra#2258) ────────────────────────────────────────────────────────────
# This script's own header calls it "the ONLY safe way to dispatch a lane order from the orchestrator",
# so the RESEARCH contract is checked HERE — on the order text, before any target resolution — for the
# same reason the three guards below exist: a refusal that arrives after the pane checks costs a
# cmux round trip and, worse, reads as a target problem when the defect is the brief.
#
# ⛔ IT APPLIES TO EVERY ORDER, not only the `@file` form: the incidents were both inline-text orders,
# and a gate that only inspected files would be the bypass the next dispatcher gravitates to.
# 80 = brief deficient (re-author) · 78 = validator missing on this box (a broken install, NOT a brief
# problem) — the two demand opposite actions, so they never share a code.
_bg_lib="${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh"
[ -f "$_bg_lib" ] || _bg_lib="$(dirname "${BASH_SOURCE[0]}")/orchestrator-harness/brief-gate.sh"
[ -f "$_bg_lib" ] || _bg_lib="${O:-$HOME/orchestrator}/brief-gate.sh"
if [ ! -f "$_bg_lib" ]; then
  echo "$LABEL: REFUSED — brief-gate.sh not found (looked in \$AGENT_INFRA_PATH/scripts/orchestrator-harness, beside this script, and \$O) — refusing to dispatch an order nothing validated"
  exit 78
fi
if ! bash "$_bg_lib" --check - lane <<<"$MSG"; then
  echo "$LABEL: REFUSED — the order did not pass the research-first gate. NOT dispatched: the target was not even resolved."
  # ⛔ A STOP IS NOT A WORK ORDER, AND THIS SCRIPT HAS NO EXEMPTION ON PURPOSE (review cycle 5, P2).
  # The advice "re-author the research section" is wrong for a STOP: there is no brief to re-author and
  # no research question to answer. Rather than add a second bypass here (safe-send.sh already owns the
  # documented STOP route, and a second one is a second thing to keep honest), name the route.
  echo "$LABEL: …if this is a STOP or a fleet ALERT rather than a work order, use safe-send.sh: it owns that route (--force for a STOP, --notice for a machine-composed alert)."
  exit 80
fi

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

cmux send --workspace "$W" "$MSG" >/dev/null 2>&1
sleep 2
cmux send --workspace "$W" $'\n' >/dev/null 2>&1
sleep 4

# Consumed check. NOTE: a message that arrives in the ORCHESTRATOR'S OWN pane would also match
# here — that is why the self-check above must pass FIRST.
if cmux read-screen --workspace "$W" --lines 10 2>&1 | grep -qiE 'Working|Steering|queued message'; then
  echo "$LABEL: CONSUMED"
  exit 0
fi
echo "$LABEL: SENT BUT NOT CONSUMED — check the pane; the text may sit in the editor"
exit 6
