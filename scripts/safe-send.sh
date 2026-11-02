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
# Usage:  safe-send.sh <workspace-uuid> <label> <brief-file> [--force|--notice]
#   --force  send anyway. Reserved for a STOP aimed at work going the wrong way,
#            where a queued instruction is still better than a silent lane.
#   --notice an ALERT, not a work order: skips ONLY the research-first brief gate
#            (#2258), because an alert has no brief and no research question — it is a
#            machine-composed message about a fleet condition. Every other guard stays
#            in force: the no-pi guard (typing into a bare shell EXECUTES), the busy
#            gate, and the dispatcher's own confirmation. It is deliberately NOT
#            `--force`: that also bypasses the busy check, and an alert must not
#            interrupt a lane mid-turn.
# Exit:   0 sent+consumed · 3 REFUSED (lane busy) · 78/80 REFUSED by the brief gate · anything else from the dispatcher
set -uo pipefail

WS="${1:-}"; LABEL="${2:-}"; FILE="${3:-}"; MODE="${4:-}"
if [ -z "$WS" ] || [ -z "$LABEL" ] || [ -z "$FILE" ]; then
  echo "usage: safe-send.sh <workspace-uuid> <label> <brief-file> [--force|--notice]" >&2
  exit 2
fi
case "$MODE" in
  ""|--force|--notice) : ;;
  *) echo "safe-send.sh: unknown mode '$MODE' (use --force for a STOP, --notice for a machine-composed ALERT)" >&2
     exit 2 ;;
esac
if [ ! -f "$FILE" ]; then
  echo "MISSING brief file: $FILE" >&2
  exit 2
fi

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"     # safe-send lives beside lane-status.py

# ── THE BRIEF GATE (agent-infra#2258) ────────────────────────────────────────────────────────────
# `<brief-file>` is the argument, so the RESEARCH contract is checked on exactly what is about to be
# typed into a lane — before the pane probes, because a refusal should name the BRIEF, not send the
# operator to re-read a pane that is fine.
#
# ⛔ `--force` IS EXEMPT, AND THE EXEMPTION IS NAMED RATHER THAN IMPLIED. `--force` here already has
# one documented meaning — a STOP aimed at work going the wrong way, "where a queued instruction is
# still better than a silent lane" — and a STOP is not a brief: requiring a research section on it
# would delay the one message whose value is that it arrives now, i.e. the gate would cause the harm
# it exists to prevent. Every other send is gated. (The same file's no-pi guard above is NOT exempt:
# it stays in force for --force too, because typing a brief into a bare shell executes it.)
# ⛔ `--notice` IS EXEMPT FOR THE SAME REASON, AND IT IS THE ALERT PATH (review cycle 5, P1).
# `tools/fleet/outcome_canary.py` composes the fleet's only controller alert and sends it through THIS
# script with no mode. With the brief gate unconditional, every alert was refused 80 — and then
# classified AMBIGUOUS and SUPPRESSED (the canary retries only on a refusal), so the controller was
# never told and the report claimed "bytes may have landed" about a message provably never sent. An
# alert is not a work order: it has no brief and asks no research question. The exemption is scoped to
# this gate ONLY — the no-pi guard below still applies, because an alert typed into a bare shell
# would be EXECUTED. (Chosen over reusing `--force`, which also bypasses the busy check and must not
# be spent on a routine alert.)
# 80 = brief deficient (re-author) · 78 = validator missing on this box (a broken install).
# ⛔ 80, NOT 74: 74 is AGENT_LAND_BACKLOG (and pi's own EX_IOERR), so sharing it made one code mean
# "re-author the brief" and "the landing ratio is over the ceiling" — opposite remedies (#2258 review).
if [ "$MODE" != "--force" ] && [ "$MODE" != "--notice" ]; then
  _bg_lib="${AGENT_INFRA_PATH:-}/scripts/orchestrator-harness/brief-gate.sh"
  [ -f "$_bg_lib" ] || _bg_lib="$SCRIPTS/orchestrator-harness/brief-gate.sh"
  [ -f "$_bg_lib" ] || _bg_lib="${O:-$HOME/orchestrator}/brief-gate.sh"
  if [ ! -f "$_bg_lib" ]; then
    echo "REFUSED [$LABEL] $WS — brief-gate.sh not found (looked in \$AGENT_INFRA_PATH/scripts/orchestrator-harness, this checkout, and \$O) — refusing to dispatch a brief nothing validated. (--force is the STOP route.)" >&2
    exit 78
  fi
  if ! bash "$_bg_lib" --check "$FILE" lane; then
    echo "REFUSED [$LABEL] $WS — $FILE did not pass the research-first gate; NOT sent, and the pane was not even read." >&2
    printf '         Re-author the brief (the [brief-gate] block above names every missing element and prints\n         the canonical section), then re-send. --force sends a STOP over this gate; --notice sends a\n         machine-composed ALERT (a fleet condition, not a work order) without a research contract.\n' >&2
    exit 80
  fi
fi

# ── IS THERE A pi IN THIS PANE AT ALL?  (added 2026-10-03) ──────────────────
# ⛔ EVERY GUARD BELOW ASKS "IS THE LANE BUSY?" — NONE ASKED WHETHER THERE IS A LANE.
# A pane whose pi has exited is a BARE LOGIN SHELL, and a brief sent to it is TYPED INTO
# THE SHELL AND EXECUTED. MEASURED 2026-10-03, after the cmux restart: a ~4 KB
# orchestrator brief was submitted to zsh on the `5&9 MCP and SDK surface` pane; zsh ran
# its embedded backtick spans as command substitutions and died with
# `zsh: parse error near 'do'`. The briefs contain backticks, `$( )` and `<N>` — so this
# is ARBITRARY COMMAND EXECUTION reachable from an ordinary queue dispatch, not a
# cosmetic error. The FAILURE MODE IS SILENT IN THE OTHER DIRECTION TOO: the lane gets
# nothing, and the dispatcher records a delivery it cannot make.
# The signal is pi's own FOOTER, which only pi draws. This check runs BEFORE --force:
# "the lane is busy" and "the lane does not exist" are different questions and --force
# (meaning "a queued instruction beats a silent lane") answers only the first.
PSCREEN="$(cmux read-screen --workspace "$WS" --lines 10 2>/dev/null)"
if [ -n "$PSCREEN" ]; then
  PLAST="$(printf '%s\n' "$PSCREEN" | sed -n '$p')"
  # ⛔ THE BUDGET LITERALS MUST COVER EVERY WINDOW THIS FLEET CAN RUN, NOT JUST THE CURRENT
  # ONE. pi draws the budget through `formatTokens`: `count < 1e6 → round(count/1000)+"k"`,
  # else `(count/1e6).toFixed(1)+"M"` — so 800000 renders `800k`, 1,000,000 renders `1.0M`
  # (NOT `1M`), and 1048576 (`kimi-k3`) also renders `1.0M`. `%/800k` is the shipped
  # 800K clamp and `%/300k` is kept for historical transcripts; `%/1.0M` is the window the
  # rollback procedure PRESCRIBES (models.json contextWindow 800000 → 1000000 — see
  # docs/ops/cost-config-policy.md §7.1 and watch-truncation.sh's printed procedure), so
  # omitting it makes this probe refuse (`exit 3`, "NO pi IN THIS PANE") a live pi pane
  # running exactly the geometry its own rollback tells the owner to adopt. `%/262k` is the
  # other shipped non-deepseek window (`qwen3.8-max`, 262144) — the same hole, and this probe
  # has no `(auto)`/model-bullet rescue arm to catch it the way the heartbeat's does.
  case "$PLAST" in
    *"%/800k"*|*"%/300k"*|*"%/1.0M"*|*"%/262k"*|*"• high"*|*"• low"*|*"• medium"*) : ;;
    *)
      if [ "$MODE" != "--force" ] || grep -qE '(%|\$|#)[[:space:]]*$' <<<"$PLAST"; then
        echo "REFUSED [$LABEL] $WS — NO pi IN THIS PANE (last line: $(printf '%s' "$PLAST" | tail -c 70))."
        echo "         A send here would be typed into a BARE LOGIN SHELL and EXECUTED."
        echo "         Relaunch the lane first (ORCHESTRATION-BOARD 72). --force does NOT override this."
        exit 3
      fi ;;
  esac
fi
# Overridable so the rc -> state mapping can be PROVEN with a stub dispatcher instead of
# by sending a real message into a real lane (which would cause the very sidetracking this
# gate exists to prevent). Defaults to the real dispatcher.
DISPATCH="${SAFE_SEND_DISPATCH:-/Users/danielospina/Documents/GitHub/tortoise/tools/cmux_dispatch.py}"

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
# cmux_dispatch.py requires Python >= 3.12; bare python3 may be 3.9 depending on PATH.
PY312="${SAFE_SEND_PYTHON:-$(command -v python3.12 || true)}"
[ -x "$PY312" ] || PY312="/Users/danielospina/.local/bin/python3.12"
[ -x "$PY312" ] || { echo "FATAL [$LABEL]: no python3.12 found -- cannot run cmux_dispatch.py"; exit 5; }
OUT=$("$PY312" "$DISPATCH" send --workspace "$WS" --label "$LABEL" --file "$FILE" 2>&1)
RC=$?
printf '%s\n' "$OUT"
case "$RC" in
  0) exit 0 ;;
  1)
    case "$OUT" in
      *"sent-but-not-consumed"*|*"not consumed"*)
        : ;; # genuine ambiguity, handled below ;;
      *)
        echo "FAILED-TO-START [$LABEL] $WS — cmux_dispatch exited 1 WITHOUT a send:"
        echo "         $OUT"
        echo "         Nothing was written; safe to retry after fixing the error above."
        exit 5 ;;
    esac
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
