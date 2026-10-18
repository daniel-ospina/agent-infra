#!/usr/bin/env bash
# tests/heartbeat-fleet-advance/run.sh — #1991: the beat must carry the FLEET ADVANCE
# standing order, not merely state.
#
# THE DEFECT (why this exists)
# ----------------------------
#   The heartbeat every orchestrator lane receives carried ROLE, MAP and PRIORITY — three
#   reminders about how to behave — and no instruction to ADVANCE anything. Measured
#   2026-10-18 before the clause was added: 12 open non-draft PRs, 8 of them closing a
#   P0/P1 issue, ALL 8 blocked, `merged_24h` unmoved for over an hour — and every beat in
#   that window read as a healthy fleet. A lane could read a beat, write a paragraph about
#   load and lanes, dispatch nothing, and the beat did not say that was wrong.
#
#   The fix is one unconditional clause in `scripts/orchestrator-heartbeat.sh` beside the
#   ROLE/MAP/PRIORITY reminders (the block the agent already reads), and it must ride the
#   SHORT FORM too: a quiet beat — no alerts, nothing actionable — is exactly when the
#   order is needed, and the short form is what a quiet beat actually receives.
#
# WHAT THIS SUITE PINS
# --------------------
#   0. WIRING IS REAL — the clause is in EXECUTABLE position in the shipped script
#      (comments stripped first, so a commented-out or deleted clause cannot read as wired),
#      and its own formation rules hold: no backticks, no double quotes, no `$` inside the
#      fragment. MSG is a DOUBLE-QUOTED assignment, so a backticked span is
#      command-substituted at assignment time and the text silently vanishes — the failure
#      mode is a hole in the shipped beat that the file on disk still looks right about.
#   1. THE QUIET BEAT (short form / PULSE) carries it — with EVERY conditional clause empty
#      (no alerts, no questions, no capacity, no dead/occupied lanes, no queue verdict), so
#      nothing but an unconditional append could have put it there.
#   2. THE FULL BEAT (alert/question form) carries it too. The two senders are different
#      message bodies, and "the short form inherits from the long one" is false — the short
#      form OVERWRITES MSG.
#   3. IT NAMES ALL THREE ORDERS AND THE CLOSING LINE — the four boxes (local + three cloud
#      VMs), AUTOPILOT, use-the-capacity-not-report-it, the P0/P1 PRs taken to the rail,
#      agent-infra/cell-2, and "a beat that reports state and dispatches nothing is a
#      WASTED BEAT". A clause present but gutted would pass a bare presence check.
#   4. THE ASSERTION IS SENSITIVE — the suite runs the SAME driver against a MUTANT of the
#      shipped script whose FLEETADV definition is emptied, and requires the fragment to be
#      ABSENT. Without this, a driver that never reached the fragment would report a
#      permanent green, which is the #991 class (a fixture that pins nothing).
#
# Run: bash tests/heartbeat-fleet-advance/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HB="$ROOT/scripts/orchestrator-heartbeat.sh"

checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }
# ⛔ A SUBSTRING TEST THAT IS NOT THE SIGPIPE IDIOM (#841/#864): a `printf … | grep -q` here
# would race under pipefail and can take the `else` branch — reporting PASS on a WITHHOLDING
# assertion, i.e. exactly backwards. A `case` glob has no upstream writer to race with.
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "0. the clause under test is the SHIPPED one"
if [ ! -f "$HB" ]; then
  echo "❌ heartbeat-fleet-advance suite: $HB not found"; exit 1
fi
# EXECUTABLE position: comments stripped BEFORE counting, so a clause that survives only in a
# comment (or was deleted) fails here rather than being "found" in the prose that explains it.
_live_hits="$(sed 's/#.*//' "$HB" | grep -c 'FLEETADV' || true)"
if [ "${_live_hits:-0}" -ge 4 ]; then
  pass "orchestrator-heartbeat.sh references FLEETADV in executable position (${_live_hits} sites)"
else
  fail "FLEETADV is absent or commented out in orchestrator-heartbeat.sh — the order would never ship"
  echo "❌ heartbeat-fleet-advance suite: the clause is not wired"; exit 1
fi
# ⛔ THE ORDER MUST SAY THE SAME THING ON BOTH BODIES. Two lengths exist (full for the alert body,
# short for the pulse), which is the file's own precedent for ROLE/MAP/PRIORITY — but two wordings
# can silently diverge, so every ELEMENT the owner named is asserted as a marker on BOTH. A variant
# that drops one (the four boxes, the rail, cell-2, the closing line) fails here, not in production.
FRAGMENTS=("FLEET ADVANCE" "ALL FOUR BOXES" "AUTOPILOT" "USE THE CAPACITY" "DRIVE THE P0/P1"
           "agent-infra" "cell-2" "scripts/admin-merge.sh" "WASTED BEAT")
# The definition lines must each be a single double-quoted literal with NOTHING inside that bash
# would interpret: no `"` (terminates the literal early), no backtick (command substitution), no `$`
# (expansion). This is the rule the file itself states for MSG, asserted mechanically on each variant.
for _v in FLEETADV FLEETADV_SHORT; do
  _defn="$(sed -n "s/^$_v=\\(.*\\)$/\\1/p" "$HB" | head -1)"
  case "$_defn" in
    \"*\") _inner="${_defn#\"}"; _inner="${_inner%\"}"
           case "$_inner" in
             *'"'*) fail "$_v contains a double quote — it would terminate the literal early" ;;
             *'`'*) fail "$_v contains a backtick — bash would command-substitute it away at assignment" ;;
             *'$'*) fail "$_v contains a dollar sign — bash would expand it at assignment" ;;
             *) if [ -z "$_inner" ]; then
                  fail "$_v is defined but EMPTY — that body would lose the order"
                else
                  _miss=""
                  for _f in "${FRAGMENTS[@]}"; do
                    has "$_inner" "$_f" || _miss="$_miss [$_f]"
                  done
                  if [ -z "$_miss" ]; then
                    pass "$_v is one self-contained literal and names every required element (${#_inner} chars)"
                  else
                    fail "$_v is missing required element(s):$_miss — the two bodies would diverge"
                  fi
                fi ;;
           esac ;;
    *) fail "$_v is not a single double-quoted literal on one line (got: ${_defn:0:60}…)" ;;
  esac
done
# Unconditional: the FULL-body append must be a top-level statement, never inside an `if`. A cheap
# but real structural read — indentation is how every conditional in this file is written. (The
# short-form append is indented BY DESIGN: it lives inside the short-form branch, asserted below.)
if [ "$(sed -n 's/^MSG="\${MSG} \${FLEETADV}"$//p' "$HB" | wc -l | tr -d ' ')" = "1" ]; then
  pass "the full-body append is a column-0 (unconditional) MSG statement, not an indented conditional one"
else
  fail "the FLEETADV append is not a top-level, unindented MSG assignment — it could be conditional"
fi
# ...and the two appends must use the RIGHT variant: the full one on the alert body, the short one
# after the short-form rebuild. Swapping them silently re-inflates (or guts) the quiet beat, which is
# the regression this pairing exists to prevent.
_full_use="$(sed -n 's/^MSG="\${MSG} \${FLEETADV}"$//p' "$HB" | wc -l | tr -d ' ')"
_short_use="$(sed -n 's/^  MSG="\${MSG} \${FLEETADV_SHORT}"$//p' "$HB" | wc -l | tr -d ' ')"
if [ "${_full_use:-0}" = "1" ] && [ "${_short_use:-0}" = "1" ]; then
  pass "the FULL variant rides the alert body and the SHORT variant rides the short-form rebuild"
else
  fail "the two variants are not where they belong (full-body uses=$_full_use, short-form uses=$_short_use)"
fi

echo ""
# ── the driver ───────────────────────────────────────────────────────────────────────
# A SANDBOXED FULL TICK, not an extraction of the MSG lines: the message is whatever the
# script actually SENDS. Everything the tick reaches for is a stub under $HOME (its own
# resolution root — SCRIPTS/STATE/SD all come from $HOME), plus a `cmux` on $PATH that
# records the send. Nothing here touches real fleet state, and no network is used.
#
# The `--rows`/ASK knobs are what select the two message bodies:
#   ask=0  every conditional input empty -> the QUIET/PULSE path -> the SHORT FORM
#   ask=1  a routed question             -> the full form (legend + standing clauses)
# ⛔ The short form is not "the long form minus text": it REBUILDS MSG from scratch, which is
# why both are driven here rather than assuming one covers the other.
sandbox(){ # sandbox <dir> <ask:0|1>
  local h="$1" ask="$2"
  mkdir -p "$h/.pi/agent/scripts" "$h/.pi/agent/state" "$h/.pi/agent/sessions/s1" "$h/bin"
  # The registry only has to be READABLE (the tick exits early without it) — its content is
  # never the subject of this suite.
  printf 'lane\tws\tsid\n' > "$h/.pi/agent/state/lane-registry.tsv"
  # Every helper the tick calls, answered offline. `count=0` / `pass=0` / no VERDICT= keep
  # every conditional clause EMPTY, which is what makes assertion 1 a proof of unconditionality.
  printf '#!/usr/bin/env python3\nprint("ASK pass=0 bounce=%s answered=0 scan_failed=0")\n' \
    "$ask" > "$h/.pi/agent/scripts/ask-owner.py"
  printf '#!/usr/bin/env python3\nprint("count=0")\n' > "$h/.pi/agent/scripts/undelivered-answers.py"
  printf '#!/usr/bin/env python3\nprint("DELIVERY 12 open PRs, 8 merged today, 8 P0/P1 PRs blocked")\n' \
    > "$h/.pi/agent/scripts/beta-progress.py"
  printf '#!/usr/bin/env python3\nprint("QUEUE: 12 open, no verdict")\n' > "$h/.pi/agent/scripts/merge-queue.py"
  printf '#!/usr/bin/env python3\nprint("OBJECTIVE ok")\n' > "$h/.pi/agent/scripts/objective.py"
  printf '#!/usr/bin/env python3\nimport json,sys\njson.dump([], sys.stdout)\n' \
    > "$h/.pi/agent/scripts/lane-status.py"
  chmod +x "$h/.pi/agent/scripts"/*.py
  # `cmux` — the orchestrator pane must report a live pi (else the liveness guard withholds the
  # send), the pane must not look mid-turn (else the idle guard withholds it), and `send` is
  # recorded verbatim into the session file the tick then greps to verify its own delivery.
  local ws; ws="$(sed -n 's/^ORCH_WS="\(.*\)"$/\1/p' "$HB")"
  cat > "$h/bin/cmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  sessions) echo "workspace=$ws pid_exists=yes label=orchestrator" ;;
  read-screen) echo "  idle at the prompt" ;;
  send) _last=""; for _a in "\$@"; do _last="\$_a"; done
        printf '%s' "\$_last" >> "\$HOME/.pi/agent/sessions/s1/hb-11111111-1111-1111-1111-111111111111.jsonl" ;;
  surface) echo "--session' '11111111-1111-1111-1111-111111111111'" ;;
esac
exit 0
EOF
  chmod +x "$h/bin/cmux"
}
beat(){ # beat <home> <script> -> the message the tick SENT
  ( HOME="$1" PATH="$1/bin:$PATH" bash "$2" >/dev/null 2>&1 )
  cat "$1/.pi/agent/sessions/s1/hb-11111111-1111-1111-1111-111111111111.jsonl" 2>/dev/null
}
FRAGMENTS=("FLEET ADVANCE" "ALL FOUR BOXES" "AUTOPILOT" "USE THE CAPACITY" "DRIVE THE P0/P1"
           "agent-infra" "cell-2" "scripts/admin-merge.sh" "WASTED BEAT")

# (the marker array is declared in section 0 above — one definition, so the wiring check and the
# behavioural checks cannot assert different element sets)

echo "1. a QUIET beat (short form) carries the order — with every conditional clause EMPTY"
h="$TMP/quiet"; sandbox "$h" 0
out="$(beat "$h" "$HB")"
if [ -z "$out" ]; then
  fail "the quiet beat produced NO message — the tick exited before sending (guard changed?)"
else
  if has "$out" "No alerts."; then
    pass "the quiet beat really is the SHORT form (the body that overwrites MSG)"
  else
    fail "the quiet beat was not the short form — assertion 1 is not testing the overwrite path"
  fi
  # Nothing conditional had anything to say: no alerts, no capacity, no dead/occupied lanes,
  # no merge-queue or objective verdict. The clause cannot have arrived from any of them.
  if has "$out" "CAPACITY:" || has "$out" "DEAD LANES" || has "$out" "NO LIVE pi RECORD" \
     || has "$out" "MERGE-QUEUE BOTTLENECK"; then
    fail "the quiet sandbox emitted a conditional clause — assertion 1 would not prove unconditionality"
  else
    pass "no conditional clause fired in the quiet beat (so only an unconditional append could add it)"
  fi
  for f in "${FRAGMENTS[@]}"; do
    if has "$out" "$f"; then pass "  quiet beat names: $f"; else fail "  quiet beat is MISSING: $f"; fi
  done
  # ⛔ PROPORTIONALITY, measured: the quiet body exists to stay readable, so the SHORT variant must
  # ride it. If a future edit points the pulse path at the full text, the quiet beat roughly doubles
  # — that is the regression (full text = 758 chars against a 985-char body, +77%), and it is
  # invisible to a marker check because both variants carry every element.
  _qlen=${#out}
  if [ "$_qlen" -lt 2000 ]; then
    pass "the quiet beat stays short with the order on it (${_qlen} chars — the full variant alone is ~758)"
  else
    fail "the quiet beat is ${_qlen} chars — the FULL variant appears to ride the pulse path"
  fi
fi

echo ""
echo "2. the FULL beat (a routed question) carries it too"
h="$TMP/full"; sandbox "$h" 1
out="$(beat "$h" "$HB")"
if [ -z "$out" ]; then
  fail "the full beat produced NO message — the tick exited before sending (guard changed?)"
else
  if has "$out" "needing attention." && has "$out" "Verdict legend suppressed" ; then
    fail "the question beat took the short-form path — the full body is what needs pinning"
  elif has "$out" "needing attention."; then
    pass "the question beat really is the FULL form (its own body, built before the short-form overwrite)"
  else
    fail "the question beat carried neither form's marker — the message shape changed unexpectedly"
  fi
  for f in "${FRAGMENTS[@]}"; do
    if has "$out" "$f"; then pass "  full beat names: $f"; else fail "  full beat is MISSING: $f"; fi
  done
  # The full body carries the FULL wording — the alert tick is where the specific instructions
  # (name the PRs, the rail, the four boxes on separate lines) are worth their length.
  if has "$out" "name the specific PRs that should land this cycle"; then
    pass "the full beat carries the FULL wording (it names the PRs that should land this cycle)"
  else
    fail "the full beat does not carry the full wording — the alert body got the condensed variant"
  fi
fi

echo ""
echo "3. SENSITIVITY: the same driver against a mutant of the shipped script must FAIL"
# The mutant empties BOTH definitions and nothing else, so the ONLY difference in the delivered
# beat is the clause. If the fragment still appears, this suite's driver is reading something
# other than the shipped clause and would be permanently green.
MUT="$TMP/mutant.sh"
/usr/bin/python3 - "$HB" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines(True)
open(dst, "w", encoding="utf-8").writelines(
    ("FLEETADV=\"\"\n" if ln.startswith("FLEETADV=") else
     "FLEETADV_SHORT=\"\"\n" if ln.startswith("FLEETADV_SHORT=") else ln) for ln in lines)
PY
h="$TMP/mutant"; sandbox "$h" 0
out="$(beat "$h" "$MUT")"
if [ -z "$out" ]; then
  fail "the MUTANT produced no message — the sensitivity check could not run, so nothing is pinned"
elif has "$out" "FLEET ADVANCE"; then
  fail "the MUTANT still carried the clause — the assertions above are not reading the shipped clause"
else
  pass "emptying FLEETADV removes the clause from the same driver (the assertions are sensitive)"
fi

echo ""
if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-fleet-advance suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-fleet-advance suite: $failures of $checks assertion(s) failed"
exit 1
