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
    # The terminating Enter FAILED (raised, or cmux exited non-zero), so submission was never
    # attempted. Do NOT prescribe a re-send: the payload is already in that pane's composer, and
    # re-sending duplicates the order.
    # ⛔ AND DO NOT ASSERT A TRANSCRIPT READ THAT MAY NOT HAVE RUN (#1881 review P2). No transcript
    # may have been resolvable at all, in which case "the transcript records no such message" is a
    # claim about evidence we never read. The remedy is the same either way, so name both branches.
    echo "$LABEL: SENT BUT NOT SUBMITTED — the terminating Enter FAILED, so the payload was typed"
    echo "$LABEL:   into the pane and never submitted (the transcript records no such message, or no"
    echo "$LABEL:   transcript could be consulted at all)."
    echo "$LABEL:   Submit it IN THAT PANE, then re-check; do NOT treat this as delivered (#1187)."
    exit 6 ;;
  PANE_ONLY)
    rm -f "$_cmux_payload_err"
    # The tail is on the surface but nothing proves SUBMISSION. The composer renders what it holds,
    # so a message that was typed and never submitted looks delivered.
    # ⛔ IT MUST NOT ASSERT A CHECK THAT DID NOT RUN (#1881 review P2). The old text claimed "the
    # lane's transcript shows no such message" even when NO transcript could be resolved (no session
    # binding, or a file this very send was about to create) — a claim about evidence we never read,
    # attached to a remedy that invites a duplicate order. Name both branches instead.
    echo "$LABEL: SENT BUT NOT SUBMITTED — the payload tail is VISIBLE on the pane, but no SUBMISSION"
    echo "$LABEL:   evidence was found: the lane's transcript shows no such message after this send,"
    echo "$LABEL:   or no transcript could be consulted at all. Delivery is therefore NOT proven."
    echo "$LABEL:   CHECK THE PANE FIRST; if the text is sitting in the composer, press Enter there."
    echo "$LABEL:   Re-send ONLY if the pane no longer holds it — a re-send can duplicate the order."
    exit 6 ;;
  *)
    # ⛔ IT MUST NOT ASSERT WHAT IT DID NOT OBSERVE (#1881 review, round 4 — non-blocking P2). This arm
    # also receives the case where `cmux send` ITSELF exited non-zero: nothing was typed and neither
    # the pane nor the transcript was read, so "SENT" and "the TAIL is not on the pane" were both
    # claims about evidence that was never gathered (a shimmed `cmux` whose send exits 1 — "Access
    # denied" — reaches exactly here). The direction stays fail-closed (exit 6, nothing recorded as
    # delivered), but the wording names the two branches and points at the checker's own
    # diagnostics, which distinguish a refused send from a lost tail.
    echo "$LABEL: NOT VERIFIED AS DELIVERED — the payload tail was not confirmed."
    echo "$LABEL:   Either cmux refused the send (nothing was typed) or it delivered a PREFIX under"
    echo "$LABEL:   load (#1187); the checker's diagnostics below say which when it printed any."
    echo "$LABEL:   CHECK THE PANE FIRST: a lane queued behind a busy turn can take a minute or more"
    echo "$LABEL:   to flush its transcript."
    echo "$LABEL:   Re-send only once the pane shows the order is absent; for a long body, write it"
    echo "$LABEL:   to a file and send a short one-line pointer (newlines are collapsed anyway)."
    if [ -s "$_cmux_payload_err" ]; then
      echo "$LABEL:   checker diagnostics: $(tr '\n' ' ' <"$_cmux_payload_err" | tail -c 300)"
    fi
    rm -f "$_cmux_payload_err"
    exit 6 ;;
esac
