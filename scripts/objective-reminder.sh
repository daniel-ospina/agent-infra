#!/usr/bin/env bash
# objective-reminder.sh — put the operator's objective in front of the running agent every N minutes.
#
# ⛔ WHY A SCHEDULED REMINDER AT ALL. The controller keeps cycling and the lanes keep working, so a
# drifted objective is not a failure any health predicate can see: every component is "alive" while the
# fleet optimises the wrong thing. The reminder is the one datum that is not a process or a log line —
# it is the operator's intent, repeated into the agent's own surface. On a Mac that surface is a cmux
# terminal; on a cell it is the controller's tmux session, which is why delivery is BACKEND-AWARE
# (below) rather than a hardcoded `cmux` call.
#
# ⛔ HARD-WON CONSTRAINT 1 — THE PAYLOAD HAS A BYTE BUDGET, AND OVER BUDGET IS A REFUSAL, NOT A SHRUG.
# Measured on this box: a cmux send of ~969 B failed `Failed to write to socket (Broken pipe)`; ~520 B
# was reliable. Then the reminder GREW (a live triage line was appended), reached ~750 B, and it
# silently stopped delivering for three consecutive ticks (04:30, 04:41, 04:51 — all "send refused")
# while the log looked like a channel that simply had nothing to say. That is the worst shape a
# reminder can fail in: the ABSENCE of a reminder is indistinguishable from a reminder that was sent.
# So the composed text is BUDGETED (`MAX_BYTES`, default 420) — over budget the optional triage line
# is dropped, and if the FIXED objective alone is still over budget the pass REFUSES LOUDLY
# (`REFUSED` in the log, and no send at all) instead of handing the socket a payload it will truncate.
# The budget is checked in BYTES (`wc -c`), not `${#}` characters: a multi-byte character is one
# character and two or three bytes, and the socket counts bytes.
#
# ⛔ HARD-WON CONSTRAINT 2 — DELIVERY IS CONFIRMED, AND THE CONFIRMATION IS A TURN BOUNDARY.
# A send that exits 0 while the text sits in the composer is the UNSENT state, and reporting it as
# delivered is how a dead channel looks healthy. The confirmation is `latest_submitted_at` on the cmux
# workspace — it advances when the message becomes a TURN.
#   ✗ NOT `latest_submitted_message`: it LAGS. It still showed the previous prompt while the reminder
#     had already been delivered and read, which produced a false "UNSENT" (a false red on a working
#     channel — the failure that gets a check switched off).
#   ✗ NOT the send's exit status: exit 0 is bytes-on-a-socket, not a turn.
# ⛔ AND THE BOUNDARY LAGS THE SEND BY MORE THAN THE SCRIPT'S OWN `sleep`: it advances when the agent
# reaches a turn boundary, which can be seconds to minutes later. So a same-pass check reports UNSENT
# for a message that in fact arrived (measured). The judgment is therefore DEFERRED: each pass records
# the boundary it saw at send time, and the NEXT pass says CONFIRMED or STILL-UNCONFIRMED. Only the
# immediate "the composer still holds our text" read can condemn a send in the same pass — that is the
# UNSENT arm, and it is the one that catches a swallowed Enter.
#
# ⛔ THE RELEASE-ENTER. If the composer is already holding unsent text (a half-typed instruction), the
# reminder concatenates onto it and the agent receives one truncated brief instead of two messages
# (measured: the pointer is eaten). So a bare Enter is sent first, deliberately turning the held text
# into its own turn, and only then is the reminder composed and sent as ONE line (newlines folded) so a
# partial write cannot leave a multi-line payload half-entered.
#
# BACKENDS. `auto` (default) picks cmux when its binary exists, else tmux.
#   cmux  macOS / the operator's box: send --workspace/--surface, read-screen, list-workspaces --json.
#   tmux  a Linux cell: there is no cmux app and no cmux binary (pi-bootstrap/cell-install.sh denies
#         even the cmux extension on a cell), so the same protocol runs over `tmux send-keys` /
#         `tmux capture-pane`. The turn-boundary analogue is the pane's HISTORY: a submitted message
#         moves into scrollback and leaves the input line empty, so "delivered" is "the payload is in
#         the captured pane AND is not on the last non-empty line", and "UNSENT" is "the payload IS on
#         that last line". It is a weaker signal than `latest_submitted_at` and is documented as such.
#
# SCHEDULING. This file is the PASS; it declares no scheduler. macOS: templates/launchd/
# com.eldato.objective-reminder.plist (StartInterval 600), rendered by install-launchd.sh. Linux cell:
# templates/systemd/eldato-objective-reminder.{service,timer}, rendered by install-cell-timers.sh —
# the same systemd timers the cell already uses for its disk reaper. No cron anywhere (`crontab`
# writes fail with EINTR on the operator's Mac — recorded).
#
# EXIT 0 ALWAYS. A non-zero exit would report a reminder RUN failure where the useful fact is a
# DELIVERY verdict, and the verdict is in `$LOG`. (The inventory row reads that non-zero status too, so
# exit codes are not free: `scripts/lib/fleet-inventory.sh` reports the job FAILING on one.)
#
# Usage: objective-reminder.sh [--status]
#   --status  print the log tail and the current backend/surface resolution (the human surface)
#
# Env seams (tests + unusual boxes):
#   BACKEND       auto | cmux | tmux        (default auto)
#   WS SURFACE    cmux workspace/surface ids
#   TMUX_TARGET   tmux target (default $SESSION, else `orch`)
#   CMUX          the cmux binary (default /opt/homebrew/bin/cmux)
#   TMUX          the tmux binary (default `tmux` on PATH)
#   MAX_BYTES     the budget for the COMPOSED text (default 420)
#   OBJECTIVE     the fixed objective text   (default below; the operator's own words)
#   TRIAGE        an optional extra line     (default: read from $TRIAGE_CMD if it resolves)
#   TRIAGE_CMD    a command whose first line is the triage addendum (default: the live ai_pr_status.py
#                 if present — it is NOT shipped by this repo, see the note in the row's detail)
#   STATE         state dir (default $HOME/.pi/agent/state)
#   LOG           decision log   (default $STATE/objective-reminder.log)
#   PENDING       the deferred-confirmation marker (default $STATE/objective-reminder.pending)
#   SETTLE        seconds to wait after the send before the composition read (default 2)
set -uo pipefail

STATE="${STATE:-$HOME/.pi/agent/state}"
LOG="${LOG:-$STATE/objective-reminder.log}"
PENDING="${PENDING:-$STATE/objective-reminder.pending}"
MAX_BYTES="${MAX_BYTES:-420}"
SETTLE="${SETTLE:-2}"
BACKEND="${BACKEND:-auto}"
CMUX="${CMUX:-/opt/homebrew/bin/cmux}"
TMUX="${TMUX:-tmux}"
WS="${WS:-443A7DFB-3A05-4318-9606-451C768D1874}"
SURFACE="${SURFACE:-0D4F1EFD-C705-468F-8D00-85ACA3FD1AB4}"
TMUX_TARGET="${TMUX_TARGET:-}"   # explicit only; resolved below (a cell has no single obvious target)

# The objective is the operator's intent in the operator's own terseness. It is FIXED text (no
# computed addition) because the budget has to be bounded by something that cannot grow on its own —
# the growth that broke delivery was an appended live line, not a longer objective.
OBJECTIVE="${OBJECTIVE:-OBJECTIVE(10m): is work ADVANCING? cells used fully (4=harness, 1+3=tortoise) · auto-dispatch local+cloud · real P0/P1 PRODUCT capacity · no main<->cells divergence · harness=ONE self-healing system · capacity by measured load, never a trickle cap. Qs saved for morning — advance what is possible.}"
TRIAGE="${TRIAGE-}"
TRIAGE_CMD="${TRIAGE_CMD:-$HOME/.pi/agent/scripts/ai_pr_status.py}"

mkdir -p "$STATE" 2>/dev/null || true
log_line() { printf '%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null; }
bytes() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }

if [ "${1:-}" = "--status" ]; then
  printf 'backend=%s cmux=%s tmux=%s target=%s budget=%s\n' \
    "$BACKEND" "$CMUX" "$TMUX_TARGET" "$MAX_BYTES"
  [ -f "$PENDING" ] && printf 'pending=%s\n' "$(cat "$PENDING" 2>/dev/null)"
  [ -f "$LOG" ] && tail -20 "$LOG" || printf 'no log at %s\n' "$LOG"
  exit 0
fi

# ── backend resolution ───────────────────────────────────────────────────────────────────────────
resolve_backend() {
  case "$BACKEND" in
    cmux|tmux) printf '%s\n' "$BACKEND"; return 0 ;;
    auto) ;;
    *) log_line "SKIP: unknown BACKEND '$BACKEND' (want auto|cmux|tmux)"; return 1 ;;
  esac
  if [ -x "$CMUX" ]; then printf 'cmux\n'; return 0; fi
  if command -v "$TMUX" >/dev/null 2>&1; then printf 'tmux\n'; return 0; fi
  return 1
}
# resolve_tmux_target — WHICH SURFACE IS AN AGENT, decided from the live box. A cell has no operator
# and no cmux: the agent that must see the objective is a lane running in a `lane-*` tmux session, so
# that is chosen first. `$SESSION` (the cell supervisor's own session name) is next, and `orch` — the
# controller's session — is LAST: a controller is a bash loop, not an agent, and typing into it is a
# no-op reminder that only exists to make a log line. Ordering it last keeps a box with lanes correct
# and a box without them honest.
resolve_tmux_target() {
  [ -n "$TMUX_TARGET" ] && { printf '%s\n' "$TMUX_TARGET"; return 0; }
  local t=""
  t="$("$TMUX" list-sessions -F '#{session_name}' 2>/dev/null | grep -m1 '^lane-' 2>/dev/null)" || t=""
  [ -n "$t" ] && { printf '%s\n' "$t"; return 0; }
  [ -n "${SESSION:-}" ] && { printf '%s\n' "$SESSION"; return 0; }
  printf 'orch\n'
}

BE="$(resolve_backend)" || { log_line "SKIP: no delivery backend (cmux not at $CMUX, tmux not on PATH) — nothing was sent"; exit 0; }
[ "$BE" = tmux ] && TMUX_TARGET="$(resolve_tmux_target)"
# The needle is the payload's own stable prefix (before the first colon), so an operator who changes
# OBJECTIVE does not silently disable the composer read — a hardcoded string would make the UNSENT arm
# and the delivered arm both unreachable, i.e. the check would report "unconfirmed" for ever.
NEEDLE="${NEEDLE:-${OBJECTIVE%%:*}}"
[ -n "$NEEDLE" ] || NEEDLE="${MSG:0:16}"

# ── compose, under the byte budget ───────────────────────────────────────────────────────────────
# The triage line is OPTIONAL and is the only part allowed to be dropped. It is capped too: a triage
# line that is one long refusal message would otherwise eat the whole budget and the objective (the
# part that matters) would be the part that gets cut.
if [ -z "$TRIAGE" ] && [ -n "$TRIAGE_CMD" ] && [ -f "$TRIAGE_CMD" ] && command -v python3 >/dev/null 2>&1; then
  t="$(python3 "$TRIAGE_CMD" 2>/dev/null | head -1 | sed 's/^ *//')" || t=""
  [ -n "$t" ] && TRIAGE=" | $t"
fi
if [ -n "$TRIAGE" ]; then
  TRIAGE_MAX=$(( MAX_BYTES / 2 ))
  if [ "$(bytes "$TRIAGE")" -gt "$TRIAGE_MAX" ]; then TRIAGE="${TRIAGE:0:$TRIAGE_MAX}…"; fi
fi
MSG="$OBJECTIVE$TRIAGE"
if [ "$(bytes "$MSG")" -gt "$MAX_BYTES" ]; then
  MSG="$OBJECTIVE"
  log_line "BUDGET: triage line dropped (composed text over ${MAX_BYTES} B) — sending the objective alone"
fi
if [ "$(bytes "$MSG")" -gt "$MAX_BYTES" ]; then
  # ⛔ THE REFUSAL. Sending this would truncate mid-instruction (or break the socket, measured ~969 B),
  # and a truncated objective is worse than none: it reads as a different, shorter objective.
  log_line "REFUSED: objective text alone is $(bytes "$MSG") B (budget ${MAX_BYTES}) — nothing sent; shorten the objective"
  exit 0
fi
# ONE line: a multi-line payload can half-enter the composer on a partial write.
MSG="$(printf '%s' "$MSG" | tr '\n\r\t' '   ')"

# ── one delivery attempt, per backend ───────────────────────────────────────────────────────────
# cmux_turn_boundary — the confirmation datum. Empty when it cannot be read (never treated as advanced).
cmux_turn_boundary() {
  "$CMUX" list-workspaces --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ws=d.get("workspaces") or []
for w in ws:
    if w.get("id")==sys.argv[1] or w.get("surface_id")==sys.argv[2]:
        print(w.get("latest_submitted_at") or ""); break
else:
    print((ws[0].get("latest_submitted_at") if ws else "") or "")
' "$WS" "$SURFACE" 2>/dev/null
}

compose_holds_text() { # does the AGENT's input surface still hold our payload?
  case "$BE" in
    cmux) "$CMUX" read-screen --workspace "$WS" --surface "$SURFACE" --lines 8 2>/dev/null | grep -qF "$NEEDLE" ;;
    tmux) "$TMUX" capture-pane -p -t "$TMUX_TARGET" 2>/dev/null | awk 'NF{l=$0} END{print l}' | grep -qF "$NEEDLE" ;;
  esac
}

deliver() {
  case "$BE" in
    cmux)
      # Release any text already in the composer into its own turn, then send ours.
      "$CMUX" send --workspace "$WS" --surface "$SURFACE" "" 2>/dev/null
      "$CMUX" send-key --workspace "$WS" --surface "$SURFACE" enter 2>/dev/null
      sleep 1
      BEFORE="$(cmux_turn_boundary)"
      "$CMUX" send --workspace "$WS" --surface "$SURFACE" "$MSG" 2>>"$LOG" || return 1
      "$CMUX" send-key --workspace "$WS" --surface "$SURFACE" enter 2>/dev/null
      ;;
    tmux)
      # Same protocol over tmux. `-l` sends the text LITERALLY: without it tmux interprets key names
      # in the payload (a `·` is fine, but a `C-m` or `Enter` token inside the objective would be
      # executed as a keystroke instead of typed).
      "$TMUX" send-keys -t "$TMUX_TARGET" Enter 2>/dev/null
      sleep 1
      BEFORE="$("$TMUX" capture-pane -p -t "$TMUX_TARGET" 2>/dev/null | awk 'NF{n++} END{print n+0}')"
      "$TMUX" send-keys -l -t "$TMUX_TARGET" "$MSG" 2>>"$LOG" || return 1
      "$TMUX" send-keys -t "$TMUX_TARGET" Enter 2>/dev/null
      ;;
  esac
  return 0
}

if ! deliver; then
  log_line "FAIL: send refused by the $BE backend (payload $(bytes "$MSG") B, budget ${MAX_BYTES}) — nothing confirmed"
  exit 0
fi
sleep "$SETTLE"

# ── the deferred confirmation of the PREVIOUS pass ──────────────────────────────────────────────
# Judged BEFORE this pass records its own send, so "previous" is unambiguous.
if [ -f "$PENDING" ]; then
  prev="$(cat "$PENDING" 2>/dev/null)"
  case "$BE" in
    cmux) cur="$(cmux_turn_boundary)" ;;
    tmux) cur="$("$TMUX" capture-pane -p -t "$TMUX_TARGET" 2>/dev/null | awk 'NF{n++} END{print n+0}')" ;;
  esac
  if [ -n "$prev" ] && [ -n "$cur" ] && [ "$cur" \> "$prev" ]; then
    log_line "previous reminder CONFIRMED delivered (turn boundary $prev -> $cur)"
  else
    log_line "previous reminder STILL-UNCONFIRMED (turn boundary $prev -> ${cur:-?}) — if this repeats, the surface/target is wrong"
  fi
fi

# ── the same-pass UNSENT arm ────────────────────────────────────────────────────────────────────
# The one thing a same-pass read CAN prove: the payload is still in the composer (its Enter was
# swallowed), which is UNSENT. Anything weaker says UNCONFIRMED, never "sent".
if [ ! -f "$LOG" ] || [ -z "${BEFORE:-}" ]; then BEFORE=""; fi
after=""
case "$BE" in
  cmux) after="$(cmux_turn_boundary)" ;;
  tmux) after="$("$TMUX" capture-pane -p -t "$TMUX_TARGET" 2>/dev/null | awk 'NF{n++} END{print n+0}')" ;;
esac
if compose_holds_text; then
  log_line "UNSENT: the payload is sitting in the $BE composer (turn boundary did not advance ${BEFORE:+from $BEFORE}) — the submit keystroke was swallowed"
  exit 0
fi
if [ -n "$BEFORE" ] && [ -n "$after" ] && [ "$after" \> "$BEFORE" ]; then
  log_line "sent: turn boundary advanced $BEFORE -> $after (the $BE backend submitted it)"
else
  log_line "sent: backend accepted $(bytes "$MSG") B; turn boundary ${BEFORE:-?} -> ${after:-?} — confirmation deferred to the next pass"
fi
printf '%s' "${after:-$BEFORE}" > "$PENDING" 2>/dev/null || log_line "WARN: cannot write $PENDING — the next pass will report this send as unconfirmed"
exit 0
