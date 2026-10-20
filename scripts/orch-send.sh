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
#   ⛔ NEWLINES DO NOT SURVIVE THE SEND (#1881 review P2, disclosure). A newline in a `cmux send`
#   payload is an Enter, so a multi-line body used to be submitted ONE LINE AT A TIME — each line an
#   independent chance at the #1187 truncation, while the tail check could only ever certify the
#   last one. So the payload is WHITESPACE-COLLAPSED to a single line before it is sent: an @file
#   brief with lists, code fences or blank-line structure reaches the lane as one flat line. Put
#   anything that must keep its line structure in a FILE THE LANE READS, and send its path.
#
#   ⛔ THE EXIT CODE IS NOT A DELIVERY SIGNAL (#1187). `cmux send` returns OK while
#   delivering only a PREFIX of a payload: measured 2026-09-29, a 1,962-byte message
#   arrived as its first sentence and a 1,404-byte one as its first numbered item,
#   both with OK, while a 5,464-byte message arrived intact — so size does not predict
#   delivery, and neither does a turn having started (a truncated prefix starts one).
#   The TAIL is what a prefix truncation loses, so CONSUMED is reported only when the
#   payload's tail marker was APPENDED TO THE LANE'S SESSION TRANSCRIPT after this send —
#   the transcript is the only source that certifies submission. A tail visible on the
#   PANE alone is NOT enough: the composer renders its content whether or not it was
#   submitted, so that is reported as SENT BUT NOT SUBMITTED (exit 6). Anything else is
#   SENT BUT NOT VERIFIED (exit 6). The check lives in scripts/lib/cmux_payload.py so
#   every caller uses one rule.
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
# The helper sends the payload, submits it with a terminating Enter, then polls the
# lane's session TRANSCRIPT for the payload's TAIL. A prefix truncation loses the tail,
# so absence of the tail is the signal. A non-zero helper exit (unreadable pane, cmux
# failure, no tail) is UNVERIFIED and MUST NOT be reported as a delivered order.
# The pane is checked too, but only to DISTINGUISH the states — never as delivery
# evidence, because the composer renders content that was never submitted.
# NOTE: a message that arrives in the ORCHESTRATOR'S OWN pane would also verify — the
# self-check above runs FIRST.
# ⛔ IF THE CHECKER CANNOT RUN, NOTHING IS SENT — SAY SO (#1881 review P2). This used to fall into the
# UNVERIFIED arm, which begins "SENT BUT NOT VERIFIED": false, and it prescribes "re-send", which would
# fail identically forever. The helper OWNS the send, so a missing sibling or interpreter means no send
# happened at all, and the operator needs the cause, not a re-send loop.
if [ ! -f "$SCRIPTS/lib/cmux_payload.py" ] || [ ! -x /usr/bin/python3 ]; then
  echo "$LABEL: NOT SENT — the payload-integrity checker is unavailable, so nothing was dispatched."
  echo "$LABEL:   missing: $([ -f "$SCRIPTS/lib/cmux_payload.py" ] || echo "$SCRIPTS/lib/cmux_payload.py")$([ -x /usr/bin/python3 ] || echo " /usr/bin/python3")"
  echo "$LABEL:   the checker is a FARMED sibling (pi-bootstrap/setup.sh lib_srcs, #1187); a copy"
  echo "$LABEL:   without it must not report delivery it cannot verify. Re-sync and retry."
  exit 7
fi
# stderr is KEPT, not discarded: a crashing checker used to vanish into /dev/null and the operator
# only ever saw "SENT BUT NOT VERIFIED".
_cmux_payload_err="$(mktemp "${TMPDIR:-/tmp}/orch-send-verify.XXXXXX")"
cmux_payload_verdict="$(/usr/bin/python3 "$SCRIPTS/lib/cmux_payload.py" verify \
      --workspace "$W" --text="$MSG" --screen-lines 200 \
      --timeout "${ORCH_SEND_VERIFY_TIMEOUT:-90}" 2>"$_cmux_payload_err")"
case "$cmux_payload_verdict" in
  VERIFIED)
    rm -f "$_cmux_payload_err"
    echo "$LABEL: CONSUMED (payload tail verified in the lane's transcript after this send)"
    exit 0 ;;
  SUBMIT_FAILED)
    rm -f "$_cmux_payload_err"
    # The terminating Enter ITSELF raised, so submission was never attempted. Do NOT prescribe a
    # re-send: the payload is already in that pane's composer, and re-sending duplicates the order.
    echo "$LABEL: SENT BUT NOT SUBMITTED — the terminating Enter FAILED, so the payload was typed"
    echo "$LABEL:   into the pane and never submitted (the transcript records no such message)."
    echo "$LABEL:   Submit it IN THAT PANE, then re-check; do NOT treat this as delivered (#1187)."
    exit 6 ;;
  PANE_ONLY)
    rm -f "$_cmux_payload_err"
    # The tail is on the surface but nothing proves SUBMISSION. The composer renders what it holds,
    # so a message that was typed and never submitted looks delivered.
    echo "$LABEL: SENT BUT NOT SUBMITTED — the payload tail is VISIBLE on the pane, but the lane's"
    echo "$LABEL:   transcript shows no such message after this send, so submission is NOT proven."
    echo "$LABEL:   CHECK THE PANE FIRST; if the text is sitting in the composer, press Enter there."
    echo "$LABEL:   Re-send ONLY if the pane no longer holds it — a re-send can duplicate the order."
    exit 6 ;;
  *)
    echo "$LABEL: SENT BUT NOT VERIFIED — the payload TAIL is not on the pane and not in the transcript."
    echo "$LABEL:   cmux send returns OK while delivering only a PREFIX under load (#1187),"
    echo "$LABEL:   so this send is NOT recorded as delivered. CHECK THE PANE FIRST: a lane queued"
    echo "$LABEL:   behind a busy turn can take a minute or more to flush its transcript."
    echo "$LABEL:   Re-send only once the pane shows the order is absent; for a long body, write it"
    echo "$LABEL:   to a file and send a short one-line pointer (newlines are collapsed anyway)."
    if [ -s "$_cmux_payload_err" ]; then
      echo "$LABEL:   checker diagnostics: $(tr '\n' ' ' <"$_cmux_payload_err" | tail -c 300)"
    fi
    rm -f "$_cmux_payload_err"
    exit 6 ;;
esac
