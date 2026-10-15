#!/bin/bash
# RAISE THE CLI DEADLINE. Measured 2026-10-01: `cmux workspace list` takes 0.2-2s on a
# quiet box but 13.4-15.1s at load 130+, against a fixed 15s CLI deadline — so a slow
# answer is indistinguishable from a hang (`Error: Command timed out`). That made the
# fleet look like "cmux send is dead" when it was a ~1.6s margin at high load.
# 60s removes the ambiguity. The binary itself sets this var for its own calls.
export CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC="${CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC:-60}"

# safe-send.sh — dispatch to a lane ONLY if it can actually READ the message.
#
# WHY THIS EXISTS (2026-09-29, measured, not theorised):
#   `cmux send` succeeds on a lane that is mid-turn. The text is accepted by the
#   composer and held as `Steering: …` until the current turn ends, so rc=0 means
#   "bytes written", never "message read". The orchestrator sent two briefs to the
#   `PR 2` lane while its pane read `Working`, and the owner found THREE messages
#   stacked in its queue (the two, plus an automatic nudge). A queued message is
#   not just undelivered — when the turn finally ends, the lane reads a backlog of
#   other people's instructions instead of pursuing its own next step.
#
#   The idle gate ALREADY EXISTS in `turn-classify.py`, which skips any lane whose
#   verdict is WORKING/LONG-TOOL. A direct call to `cmux_dispatch.py` bypasses it,
#   and that bypass is the entire defect. This wrapper closes it for the path the
#   orchestrator actually uses.
#
# A `Working` status bar is the signal: it is drawn at the bottom of the pane and
# only while a turn is in flight.
#
# Usage:  safe-send.sh <workspace-uuid> <label> <brief-file> [--force]
#   --force  send anyway. Reserved for a STOP aimed at work going the wrong way,
#            where a queued instruction is still better than a silent lane.
# Exit:   0 sent+consumed · 3 REFUSED (lane busy) · anything else from the dispatcher
set -uo pipefail

WS="${1:-}"; LABEL="${2:-}"; FILE="${3:-}"; MODE="${4:-}"
if [ -z "$WS" ] || [ -z "$LABEL" ] || [ -z "$FILE" ]; then
  echo "usage: safe-send.sh <workspace-uuid> <label> <brief-file> [--force]" >&2
  exit 2
fi
if [ ! -f "$FILE" ]; then
  echo "MISSING brief file: $FILE" >&2
  exit 2
fi

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"     # safe-send lives beside lane-status.py
# Overridable so the rc -> state mapping can be PROVEN with a stub dispatcher instead of
# by sending a real message into a real lane (which would cause the very sidetracking this
# gate exists to prevent). Defaults to the real dispatcher.
DISPATCH="${SAFE_SEND_DISPATCH:-$HOME/Documents/GitHub/tortoise/tools/cmux_dispatch.py}"

if [ "$MODE" != "--force" ]; then
  # read-screen can fail or resolve to another pane; a FAILED read must not read as
  # "idle" (that would send into a busy lane on a monitor outage). Treat unreadable
  # as busy -> refuse, and say so, so the caller can --force deliberately.
  # A single empty read is a TRANSIENT, not evidence of busy: a mid-turn lane and a
  # failed read both produce "no verdict", and conflating them made this gate read as a
  # permanent block (measured 2026-09-28: 7 sends refused in a row as "pane unreadable"
  # while `cmux read-screen` returned 2627 bytes when run by hand seconds later).
  SCREEN=""
  for _try in 1 2 3; do
    SCREEN="$(cmux read-screen --workspace "$WS" --lines 14 2>/dev/null)"
    [ -n "$SCREEN" ] && break
    sleep 2
  done
  if [ -z "$SCREEN" ]; then
    echo "REFUSED [$LABEL] $WS — read-screen returned NOTHING on 3 tries, so busy/idle is UNKNOWN (not idle; cmux may be down). Re-run, or --force."
    exit 3
  fi
  # ── IS IT ACTUALLY ACTIVE? ─────────────────────────────────────────────────
  # The pane/verdict pair is NOT sufficient and this was proven the hard way:
  # measured 2026-09-29, five of seven lanes read DONE-IDLE or FREE while their
  # session files were being written 0 minutes earlier -- two of them WORKING and
  # one LONG-TOOL. The briefs queued behind live turns, which is exactly the
  # distraction this gate exists to prevent. The session .jsonl mtime is the only
  # reliable liveness signal (a long tool call writes NOTHING to the pane, so a
  # wedged-looking lane and a working one are identical on screen).
  # ACTIVE_WINDOW_S: written this recently => mid-turn, do not queue behind it.
  # ── POSITIVE EVIDENCE, NOT A STALE VERDICT ─────────────────────────────────
  # WHAT WAS HERE (removed 2026-10-01): `lane-status.py --json --sample 2`, a FLEET-WIDE
  # classifier call, MEASURED at 88s (27 lanes, each with a pgrep/lsof walk), sitting
  # inside a send path the caller wrapped in a 240s timeout. On this box one cmux call
  # alone takes 13-15s at load, so it overflowed and the caller got `rc=None (timeout)` —
  # an answer of NOTHING, from which "wedged" and "slow" cannot be told apart.
  # It also asked the WRONG QUESTION. `DONE-IDLE` is a SAMPLE, not a state: a lane that
  # starts a turn one second after the read is indistinguishable from one that stayed
  # idle. Measured: a lane read DONE-IDLE and was WORKING seconds later, and it was
  # SIDETRACKED onto a different PR while its own WIP was in flight.
  #
  # lane-guard.py asks the OPPOSITE question — not "does the verdict say idle?" but "is
  # there POSITIVE evidence that nothing is in flight?" — LANE-LOCAL and BRACKETED: no
  # spinner, no child (transcript / declared / pane), the session file UNMOVED across a
  # window, and a closing re-read at the instant it answers. Measured 5-8s per lane, and
  # it REFUSES when the state is UNKNOWN rather than reading unknown as idle.
  GUARD="${SAFE_SEND_GUARD:-$SCRIPTS/lane-guard.py}"
  GOUT=$(/usr/bin/python3 "$GUARD" --ws "$WS" --label "$LABEL" 2>&1)
  GRC=$?
  if [ "$GRC" -ne 0 ]; then
    echo "REFUSED [$LABEL] $WS — $GOUT"
    echo "         Not consumable. A message sent now would QUEUE unread, or the state is"
    echo "         UNKNOWN (which is NOT idle). Wait, or --force ONLY for a STOP."
    exit 3
  fi
fi

# ── THE SEND — and NOT via `exec` ──────────────────────────────────────────
# `exec` deliberately removed: an `exec`'d send that is killed leaves the caller with NO
# state at all, while the text may already be in the composer. cmux_dispatch.py's own exit
# codes are meaningful, so they are mapped here to DEFINITE, distinguishable states:
#   0  sent + CONSUMED
#   1  sent-but-not-consumed — the bytes were written but NO turn was confirmed, so the
#      text MAY be sitting in the composer. This is AMBIGUOUS, and it is reported as its
#      OWN state (4) rather than folded into a generic failure, so a caller cannot mistake
#      it for "nothing happened" and blind-retry a second instruction on top of the first.
#   3  refused / never became ready — nothing was consumed.
OUT=$(python3 "$DISPATCH" send --workspace "$WS" --label "$LABEL" --file "$FILE" 2>&1)
RC=$?
printf '%s\n' "$OUT"
case "$RC" in
  0) exit 0 ;;
  1)
    echo "AMBIGUOUS [$LABEL] $WS — cmux_dispatch reports 'sent-but-not-consumed'."
    echo "         The bytes were written but no turn was confirmed: the text MAY be in the"
    echo "         composer. Do NOT blind-retry (that stacks a second instruction). Read the"
    echo "         composer, then release or re-send deliberately."
    exit 4 ;;
  3)
    echo "REFUSED [$LABEL] $WS — the dispatcher refused (never became ready). Nothing consumed."
    exit 3 ;;
  *)
    echo "UNKNOWN [$LABEL] $WS — cmux_dispatch rc=$RC; state NOT established. See its output above."
    exit 5 ;;
esac
