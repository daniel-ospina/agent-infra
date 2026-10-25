#!/usr/bin/env bash
# objective-reminder.test.sh — the reminder's two hard-won constraints, driven hermetically.
#
# ⛔ THE CASES THAT MATTER are the two failures that actually happened, both SILENT:
#   1. the payload grew past what the socket accepts (~969 B → Broken pipe; ~750 B refused for three
#      consecutive ticks) and the reminder simply stopped arriving — so over budget must REFUSE and send
#      NOTHING, and the refusal must not be vacuous (the same fixture under budget DOES send);
#   2. a send that exits 0 with the text still in the composer reads as delivered — so the UNSENT arm must
#      fire on the composer read, and the CONFIRMED arm must key on `latest_submitted_at` (a turn
#      boundary), NOT on `latest_submitted_message`, which lags and produced a false UNSENT.
#
# Nothing here touches cmux, a terminal, the network or $HOME: the backend is a stub we count, `$HOME` is
# throwaway, and every assertion reads the script's own log or the stub's call ledger.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
S="$HERE/objective-reminder.sh"
[ -f "$S" ] || { echo "FATAL: $S not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/objective-reminder-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'BAD  %s\n' "$*"; FAIL=$((FAIL+1)); }
FAIL=0
assert_eq()       { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (no '$2' in: $(printf '%s' "$1" | tr '\n' '|'))" ;; esac; }
assert_absent()   { case "$1" in *"$2"*) bad "$3 (found '$2')" ;; *) ok "$3" ;; esac; }

N=0
newcase() {
  N=$((N+1)); C="$WORK/c$N"; mkdir -p "$C/state" "$C/bin"
  CALLS="$C/calls"; : > "$CALLS"
  PAYLOADS="$C/payloads"; : > "$PAYLOADS"
  BOUNDARY="$C/boundary"; printf '2026-01-01T00:00:00Z' > "$BOUNDARY"
  SCREEN="$C/screen"; : > "$SCREEN"
  # The stub backend. It records every call, and it behaves like the real one for the two things the
  # script reads: the workspace JSON (`latest_submitted_at` — the confirmation datum — plus a
  # DELIBERATELY FROZEN `latest_submitted_message`, which is the lag that produced the false UNSENT) and
  # the composer screen.
  cat > "$C/bin/cmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
verb="${1:-}"
case "$verb" in
  send)
    # The payload is the last argument; the release-enter is the empty string.
    for a in "$@"; do last="$a"; done
    if [ -n "$last" ]; then
      printf '%s\n' "$last" >> "$PAYLOADS"
      [ "${STUB_SEND_RC:-0}" = 0 ] || exit 1
      : > "$CFLAG"          # a payload was typed and has not been submitted yet
    fi
    ;;
  send-key)
    # ⛔ ONLY A SUBMIT THAT FOLLOWS A PAYLOAD ADVANCES THE BOUNDARY. The release-enter (sent first, to
    # free whatever the composer was holding) creates no turn when the composer is empty — a stub that
    # advanced on EVERY enter would make `BEFORE` and `AFTER` identical and the "boundary advanced"
    # assertion unreachable, i.e. a vacuous pass.
    if [ -f "$CFLAG" ] && [ "${STUB_ADVANCE:-1}" = 1 ]; then
      # MONOTONIC, because the verdict is a STRING comparison: a constant timestamp makes every later
      # pass read "unchanged" and the CONFIRMED arm unreachable (a vacuous negative).
      n="$(cat "$BCOUNT" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$BCOUNT"
      printf '2026-01-01T00:%02d:00Z' "$n" > "$BOUNDARY"; rm -f "$CFLAG"
    fi
    ;;
  list-workspaces)
    printf '{"workspaces":[{"id":"WS","latest_submitted_at":"%s","latest_submitted_message":"an OLD prompt"}]}\n' \
      "$(cat "$BOUNDARY" 2>/dev/null)"
    ;;
  read-screen)
    cat "$SCREEN" 2>/dev/null
    ;;
esac
exit 0
STUB
  chmod +x "$C/bin/cmux"
  CFLAG="$C/submitted"; BCOUNT="$C/bcount"; export CALLS PAYLOADS BOUNDARY SCREEN CFLAG BCOUNT
}

# run <extra-env...> — one pass of the real script against this case's stub.
run() {
  env HOME="$C" STATE="$C/state" LOG="$C/state/objective-reminder.log" \
      PENDING="$C/state/objective-reminder.pending" \
      CMUX="$C/bin/cmux" BACKEND=cmux SETTLE=0 "$@" \
      bash "$S" >"$C/out" 2>&1
  printf '%s\n' "$?"
}
logtail() { tail -1 "$C/state/objective-reminder.log" 2>/dev/null; }
sends()   { wc -l < "$PAYLOADS" | tr -d ' '; }

# ═══ 1. NON-VACUITY BASELINE: a normal pass sends ONCE and confirms via the turn boundary ═════════
echo "── 1. under budget → exactly one send, confirmed by latest_submitted_at"
newcase
rc="$(run)"
assert_eq "$rc" "0" "a delivered pass exits 0"
assert_eq "$(sends)" "1" "exactly ONE payload was sent (the release-enter sends no text)"
assert_contains "$(logtail)" "sent: turn boundary advanced" "the pass reports the boundary it saw advance"
assert_contains "$(cat "$C/state/objective-reminder.pending" 2>/dev/null)" "2026-01-01T00:" \
  "…and records the boundary for the NEXT pass's deferred confirmation"

# ═══ 2. THE BYTE BUDGET: over budget REFUSES and sends NOTHING ═══════════════════════════════════
echo "── 2. over budget → REFUSED, zero sends (the silent 3-tick stop)"
newcase
rc="$(run MAX_BYTES=50)"
assert_eq "$rc" "0" "a refusal exits 0 (the verdict is the log, not the exit code)"
assert_contains "$(logtail)" "REFUSED:" "the pass says REFUSED and names the budget"
assert_contains "$(logtail)" "budget 50" "…and the budget it was judged against"
assert_eq "$(sends)" "0" "NOTHING was sent over budget — a truncated objective is a different objective"
# NON-VACUITY: the identical fixture with room in the budget DOES send. Without this line, a script that
# never sends at all would pass case 2 and look correct.
rc="$(run MAX_BYTES=420)"
assert_eq "$(sends)" "1" "NON-VACUITY: the same fixture under budget sends, so case 2 is not passing by silence"

# ═══ 3. THE UNSENT ARM: the composer still holds the payload ⇒ UNSENT, not "sent" ════════════════
echo "── 3. the composer still holds the text → UNSENT"
newcase
printf 'OBJECTIVE(10m): is work ADVANCING? …\n' > "$SCREEN"
rc="$(run STUB_ADVANCE=0)"
assert_eq "$rc" "0" "an UNSENT pass exits 0"
assert_contains "$(logtail)" "UNSENT:" "the composer read condemns the send even though it exited 0"
assert_absent "$(logtail)" "sent:" "…and it is NOT reported as sent"
# NON-VACUITY: with the composer clear and the boundary advanced, the SAME case says sent.
newcase
rc="$(run)"
assert_contains "$(logtail)" "sent:" "NON-VACUITY: a clear composer with an advancing boundary says sent"

# ═══ 4. THE CONFIRMATION DATUM: latest_submitted_at, NOT latest_submitted_message ════════════════
echo "── 4. deferred confirmation uses the turn boundary; the lagging message cannot cause a false UNSENT"
newcase
run >/dev/null                       # pass 1 records the boundary
assert_eq "$(logtail)" "$(printf '%s' "$(logtail)" | sed -n '/sent:/p')" "pass 1 recorded a send" 2>/dev/null || true
# Pass 2: the stub's `latest_submitted_message` is FROZEN ("an OLD prompt") while the boundary advanced.
rc="$(run STUB_ADVANCE=1)"
assert_contains "$(cat "$C/state/objective-reminder.log")" "previous reminder CONFIRMED delivered" \
  "the previous send is CONFIRMED from latest_submitted_at alone (the message field is still the old prompt)"
# NON-VACUITY: a boundary that did NOT advance is NOT confirmed.
newcase
printf 'OBJECTIVE(10m): is work ADVANCING? …\n' > "$SCREEN"
run >/dev/null
rc="$(run STUB_ADVANCE=0)"
assert_contains "$(logtail)" "UNSENT:" "NON-VACUITY: an unchanged boundary with the text still in the composer is UNSENT"

# ═══ 5. A send the backend REFUSES is FAIL, and is never counted as delivered ═════════════════════
echo "── 5. a refused send is FAIL, not a silent success"
newcase
rc="$(run STUB_SEND_RC=1)"
assert_eq "$rc" "0" "a refused send still exits 0"
assert_contains "$(logtail)" "FAIL: send refused" "the pass names the refusal"
assert_absent "$(cat "$C/state/objective-reminder.log")" "CONFIRMED" "nothing is confirmed from a refused send"
assert_eq "$([ -f "$C/state/objective-reminder.pending" ] && echo 1 || echo 0)" "0" \
  "…and no pending marker is written, so the next pass does not judge a send that never happened"

echo
if [ "$FAIL" -eq 0 ]; then echo "PASS — objective-reminder: all cases ok"; exit 0; fi
echo "FAIL — $FAIL case(s)"; exit 1
