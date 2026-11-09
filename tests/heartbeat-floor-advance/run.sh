#!/bin/bash
# tests/heartbeat-floor-advance/run.sh -- #1993 regression suite for the FLEET ADVANCE order on the
# cadence FLOOR (`scripts/cadence-nudge.sh`), the sender that actually delivers most beats.
#
# THE DEFECT (why this exists)
# ----------------------------
#   #1991 put the owner's FLEET ADVANCE standing order on the TICK and spent eight review rounds
#   proving it cannot be gated, reworded or stripped on the way out. The TICK is not the dominant
#   sender: `cadence-nudge.sh` is the cadence FLOOR, driven by `cadence-timer.sh` on a fixed 450 s
#   interval and due at `PULSE_MIN` (5 min), while the tick runs once per loop pass (>= 9 min) and
#   then rate-limits ITSELF out when the last beat is under `MIN_GAP_MIN` (4 min) old. So the floor
#   lands a beat in every 7.5-min window and the tick's pass boundary usually falls inside the
#   floor's suppression window. The message a lane usually receives is the floor's -- and before
#   #1993 it carried ROLE / MODEL / NEXT / PERIODIC and no order to advance anything, so a lane
#   could read a beat, write a paragraph about load, dispatch nothing, and nothing on the line said
#   that was wrong.
#
# THE DESIGN THIS SUITE PINS
#   The order is a STATIC literal (`FLEETADV_FLOOR`) interpolated into the ONE `MSG=` assignment:
#   no read, no subshell, nothing that can block, because the floor's one invariant is that a beat
#   leaves on time on a broken box. It is the shipped tick's `FLEETADV_SHORT` sentence for sentence
#   -- a second wording would be two files telling the fleet two different things. It rides directly
#   behind the state header and BEFORE `DO:` (NOT at the tail: #1187 measured a 1,962-byte payload
#   arriving as its FIRST SENTENCE) and it is OUTSIDE `${doact}`, which the resource gate rewrites on
#   a `DO: RECLAIM` verdict -- a standing order is not a dispatch offer.
#
# DECLARED THREAT SURFACE (this is what the assertions cover; the residuals are stated at the end)
#   T1 the order ABSENT from the payload the floor actually delivers
#   T2 the order GATED -- conditional at the definition, at the reference, or around the send
#   T3 the order REWORDED, or the two senders DRIFTED apart (either file edited alone)
#   T4 the order MOVED behind the resource gate / off its declared position, or stripped on egress
#   T5 FORMATION breakage at assignment: a backtick (command-substituted and silently vanishes), a
#      `$` (expanded), a raw `"` (ends the string), or a newline (ONE MESSAGE, ONE LINE -- `cmux
#      send` submits every newline as its own turn)
#   T6 a SECOND egress, or a duplicate of the order inside the same beat
#
# STATES DRIVEN (the delivered payload is read, never the source's intent)
#   `checker`  the real `verify` path: the checker is present and answers VERIFIED
#   `raw`      no usable checker: the floor's own `cmux send` arm -- the arm that exists for a
#              broken box, i.e. exactly the box where a clause that needs something is lost
#   `bare`     no lane recap at all (the floor's degraded message): a clause keyed on a recap input
#              would be lost exactly here
#   `reclaim`  a populated `DO:` clause AND a resource verdict of `DO: RECLAIM`, so the gate really
#              fires and the order is proven to be outside the clause it gates
#
# Run: bash tests/heartbeat-floor-advance/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FLOOR="$ROOT/scripts/cadence-nudge.sh"
TICK="$ROOT/scripts/orchestrator-heartbeat.sh"

checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }
# A `case` glob, never `printf … | grep -q`: that idiom is banned outright
# (`scripts/check-no-sigpipe-grep.sh`, #841) and on a WITHHOLDING assertion a fired SIGPIPE race
# would take the `else` branch and report PASS.
has(){ case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
count_of(){ local s="$1" n="$2" c=0; while :; do case "$s" in *"$n"*) c=$((c + 1)); s="${s#*"$n"}";; *) break;; esac; done; echo "$c"; }
# Offset of the FIRST occurrence, or empty when absent -- used for the ordering assertions.
idx_of(){ local s="$1" n="$2" pre; case "$s" in *"$n"*) ;; *) echo ""; return 1 ;; esac; pre="${s%%"$n"*}"; echo "${#pre}"; }
# The shipped value of a `NAME="…"` assignment, read from the file under test. Greedy on purpose: the
# tail anchor is what a `"`-terminated literal provides, and §2 separately refuses an embedded quote
# on the definition line, so this cannot silently return half a value.
text_of(){ sed -n "s/^$2=\"\\(.*\\)\"\$/\\1/p" "$1" | head -1; }

# ── 0. the files under test, and the canonical order ─────────────────────────────────────────────
echo "0. the shipped files, and the canonical order restated from #1991"
for f in "$FLOOR" "$TICK"; do
  if [ ! -f "$f" ]; then echo "❌ heartbeat-floor-advance: $f not found"; exit 1; fi
  if bash -n "$f" 2>/dev/null; then pass "$(basename "$f") parses (bash -n)"; else fail "$(basename "$f") DOES NOT PARSE — nothing below can be trusted"; fi
done
# ⛔ FIXED HERE, NOT READ FROM THE FILE UNDER TEST. A suite that derives its expectation from the
# script it audits compares a mutant against its own mutated text and passes (a lesson #1991 paid for
# in review: five reword-mutants all stayed green). This is the owner's order, restated from #1991;
# changing it is changing what the fleet is ordered to do, and must be deliberate.
ORDER=(
  "CHECK THE cmux LANES AND ALL FOUR BOXES (local + the three cloud VMs) and push each toward AUTOPILOT — dispatching, creating PRs, fixing them, merging them UNATTENDED."
  "USE THE CAPACITY, DO NOT REPORT IT: dispatch locally if the local machine has room, on a cloud VM if it is idle."
  "DRIVE THE P0/P1 PRs: name the specific PRs that should land this cycle, take each one to the rail via scripts/admin-merge.sh, and advance agent-infra (cell-2 owns it) toward automating dispatch, PR creation, fixing and merging."
  "A beat that reports state and dispatches nothing is a WASTED BEAT."
)
FRAMING="⛔ FLEET ADVANCE — an ORDER, not a report."
WANT="$FRAMING ${ORDER[0]} ${ORDER[1]} ${ORDER[2]} ${ORDER[3]}"

# ── 1. the shipped literal IS the canonical order, and it CANNOT DRIFT from the tick ────────────
echo ""
echo "1. the clause the floor ships is #1991's order, verbatim, and the two senders cannot drift apart"
_defs="$(grep -c '^FLEETADV_FLOOR=' "$FLOOR" || true)"
if [ "${_defs:-0}" = "1" ]; then
  pass "exactly ONE FLEETADV_FLOOR definition (a second one would be a shadow that can carry a different order)"
else
  fail "${_defs:-0} FLEETADV_FLOOR definition lines (expected exactly 1)"
fi
_got="$(text_of "$FLOOR" FLEETADV_FLOOR)"
if [ -n "$_got" ] && [ "$_got" = "$WANT" ]; then
  pass "FLEETADV_FLOOR is the canonical four sentences with the framing, verbatim"
else
  # Name the first thing that does not match rather than dumping 618 bytes at the operator.
  _why="FLEETADV_FLOOR is MISSING or has no closing quote on its definition line"
  if [ -n "$_got" ]; then
    _why="(${_got:0:40}…) differs from the canonical order"
    for i in 0 1 2 3; do
      if has "$_got" "${ORDER[$i]}"; then continue; fi
      _why="sentence $((i + 1)) is missing or reworded — expected '${ORDER[$i]:0:60}…'"
      break
    done
  fi
  fail "$_why"
fi
# ⛔ THE DRIFT PIN. The floor's wording is the tick's `FLEETADV_SHORT` sentence for sentence. Two
# wordings of one standing order is the failure mode this pins: the fleet would be told two different
# things by two senders and NOTHING would be red. A change to either file that is not made to both
# fails here.
_shtext="$(text_of "$TICK" FLEETADV_SHORT)"
if [ -z "$_shtext" ]; then
  fail "the tick has no FLEETADV_SHORT literal — the drift pin cannot compare anything"
else
  _shrend="$_shtext"
  for i in 1 2 3 4; do
    _shrend="${_shrend//'${FA'$i'}'/$(text_of "$TICK" "FA$i")}"
  done
  # The tick's short literal ends with a trailing space (it is appended into a body); the floor's is a
  # standalone clause. That one byte is the only permitted difference, and it is asserted rather than
  # assumed: strip it, then require exact equality.
  case "$_shrend" in *' ') _shrend="${_shrend%' '}" ;; esac
  if [ "$_shrend" = "$WANT" ]; then
    pass "the tick's FLEETADV_SHORT renders to the SAME four sentences (the two senders cannot drift)"
  else
    fail "the tick's FLEETADV_SHORT no longer renders to the floor's order — the two senders would tell the fleet different things. tick='${_shrend:0:80}…' floor='${_got:0:80}…'"
  fi
  for i in 0 1 2 3; do
    if has "$_shrend" "${ORDER[$i]}"; then
      pass "  the tick still carries canonical sentence $((i + 1))"
    else
      fail "  the tick LOST canonical sentence $((i + 1)) — it was edited in one file only"
    fi
  done
fi

# ── 2. formation: the properties that would make the text vanish or mangle at assignment ────────
echo ""
echo "2. formation (T5): the literal survives a DOUBLE-QUOTED assignment"
_defline="$(grep -m1 '^FLEETADV_FLOOR=' "$FLOOR" || true)"
_quotes="$(printf '%s\n' "$_defline" | tr -cd '"' | wc -c | tr -d ' ')"
if [ "${_quotes:-0}" = "2" ]; then
  pass "the definition line carries exactly two double quotes (an embedded one would end the string)"
else
  fail "the definition line carries ${_quotes:-0} double quotes (expected 2) — an embedded \" ends MSG's value"
fi
if has "$_got" '`'; then
  fail "the clause contains a BACKTICK — MSG is a double-quoted assignment, so it is command-substituted at assignment time and silently DISAPPEARS"
else
  pass "no backtick in the clause (a backticked span would be executed and vanish)"
fi
if has "$_got" '$'; then
  fail "the clause contains a \$ — it would be expanded at assignment time instead of delivered"
else
  pass "no \$ in the clause (nothing to expand)"
fi
case "$_got" in
  *$'\n'*) fail "the clause contains a NEWLINE — cmux send submits every newline as its own turn (the owner's 'many individual messages' defect)" ;;
  *)       pass "the clause is a single line (no newline to split the beat into turns)" ;;
esac

# ── 3. wiring: one reference, on the ONE MSG assignment, outside the gated clause ───────────────
echo ""
echo "3. wiring (T2, T4): one reference, on the ONE MSG assignment, outside \${doact}"
_msg_assigns="$(grep -c '^MSG=' "$FLOOR" || true)"
if [ "${_msg_assigns:-0}" = "1" ]; then
  pass "the floor has exactly ONE MSG= assignment (no second body that could omit the order)"
else
  fail "${_msg_assigns:-0} MSG= assignments — the order must be in every body that can be sent"
fi
_ref_n="$(grep -c 'FLEETADV_FLOOR' "$FLOOR" || true)"
if [ "${_ref_n:-0}" = "2" ]; then
  pass "FLEETADV_FLOOR occurs on exactly 2 lines (its definition + one reference) — no duplicate append"
else
  fail "FLEETADV_FLOOR occurs on ${_ref_n:-0} lines (expected 2: definition + one reference)"
fi
# The reference must sit on the MSG= line. A reference on a `doact=`/append line is the T4 shape: the
# order would then ride the clause the resource gate rewrites (`DO: RECLAIM` -> WITHHELD).
_offmsg="$(grep -n 'FLEETADV_FLOOR' "$FLOOR" | cut -d: -f1 | while read -r _l; do
  _txt="$(sed -n "${_l}p" "$FLOOR")"
  case "$_txt" in FLEETADV_FLOOR=*) continue ;; esac
  case "$_txt" in MSG=*) continue ;; esac
  echo "$_l"
done | tr '\n' ' ')"
if [ -z "$_offmsg" ]; then
  pass "every reference to the clause is either its definition or the MSG= line (never a DO:/append)"
else
  fail "the clause is referenced on line(s) ${_offmsg}which are neither the definition nor MSG= — it was folded into a clause the resource gate can rewrite, or into a second body"
fi
# Bash executes top-down, so a definition AFTER its reference ships an EMPTY clause. Unconditionality
# itself is proven behaviourally (the `bare` and `reclaim` states below, plus the conditional mutant),
# not by a static read.
_l_def="$(grep -n '^FLEETADV_FLOOR=' "$FLOOR" | cut -d: -f1 | head -1)"
_l_msg="$(grep -n '^MSG=' "$FLOOR" | cut -d: -f1 | head -1)"
if [ -n "${_l_def:-}" ] && [ -n "${_l_msg:-}" ] && [ "$_l_def" -lt "$_l_msg" ]; then
  pass "the definition precedes the MSG= assignment (line ${_l_def} < ${_l_msg}) — the reference cannot read an empty value"
else
  fail "the definition (line ${_l_def:-?}) does not precede MSG= (line ${_l_msg:-?}) — the beat would ship an empty clause"
fi

# ── the driver ──────────────────────────────────────────────────────────────────────────────────
# A SANDBOXED REAL RUN, not an extraction of the MSG lines: the clause has to be read out of the
# payload the floor actually hands to cmux (or to the checker), because a source pin cannot tell a
# delivered order from a described one.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# ⛔ THE SANDBOX MIRRORS THE REAL LAYOUT: the floor derives SCRIPTS/STATE from `$HOME`
# (`SCRIPTS="$HOME/.pi/agent/scripts"`), so a convenience layout under `$h/scripts` tests NOTHING --
# the floor finds no log, cannot parse a previous nudge, and exits before building a message.
api(){ # api <home> — the helper stubs every state gets
  local h="$1"
  printf 'ORCH_WS="WS-TEST"\nORCH_SURFACE="SURF-TEST"\n' > "$h/.pi/agent/scripts/orchestrator-heartbeat.sh"
  # A parseable, long-past NUDGE: the floor refuses to send on an unparseable timestamp, and the due
  # read is what tells it a beat is owed.
  printf 'x NUDGE at=1000000000 delivered=yes (cadence-floor) gap=1m queue=[] alerts=[] ask=[]\n' \
    > "$h/.pi/agent/state/orchestrator-heartbeat.log"
  cp "$ROOT/scripts/lib/beat-pair.sh" "$h/.pi/agent/scripts/lib/beat-pair.sh"
  # `cmux` on PATH: in the `raw` arm it is the egress, and its LAST argv element is what the pane would
  # receive. In the `checker` arm it must NOT carry the payload — a `send` there is a second egress,
  # which §5 counts.
  cat > "$h/bin/cmux" <<'EOF'
#!/usr/bin/env bash
_last=""; for _a in "$@"; do _last="$_a"; done
printf '%s\n' "$*" >> "$HOME/cmux-calls.txt"
case "${1:-}" in
  send) printf '%s' "$_last" >> "$HOME/payload.txt" ;;
esac
exit 0
EOF
  chmod +x "$h/bin/cmux"
}
recap_state(){ # recap_state <home> — a verified recap/beat pair, so the act clause fires
  local h="$1"
  printf 'fleet=f1 | lane-x(3m)\nact=CONTINUE lane-x\nactfull=0\n' > "$h/.pi/agent/state/lane-recap.last"
  printf '# recap' > "$h/.pi/agent/state/NEEDS-ACTION.md"
  # shellcheck source=/dev/null
  ( . "$ROOT/scripts/lib/beat-pair.sh"; _mdsha "$h/.pi/agent/state/NEEDS-ACTION.md" ) > "$h/md.txt"
  printf 'act=CONTINUE lane-x\nactfull=1\nmd=%s\n' "$(cat "$h/md.txt")" > "$h/.pi/agent/state/NEEDS-ACTION.beat"
}
sandbox(){ # sandbox <home> <checker|raw> [recap|bare] [reclaim]
  local h="$1" mode="$2" state="${3:-recap}" reclaim="${4:-}"
  mkdir -p "$h/.pi/agent/state" "$h/.pi/agent/scripts/lib" "$h/bin"
  api "$h"
  if [ "$state" = recap ]; then recap_state "$h"; fi
  if [ "$reclaim" = reclaim ]; then
    # ⛔ THE GATE MUST REALLY FIRE, or §4d's ordering assertion proves nothing. `objective.py` is
    # stubbed at the path the floor calls: `--res` reports `DO: RECLAIM`, and `--gate-clause` does what
    # the shipped one does to a dispatch clause (neutralise it and say why).
    cat > "$h/.pi/agent/scripts/objective.py" <<'EOF'
import sys
a = sys.argv[1:]
if "--res" in a:
    print("RES: runq=0/8 swap=1% | DO: RECLAIM")
elif "--gate-clause" in a:
    c = sys.stdin.read().strip().replace("hand the next unheld item", "WITHHELD")
    print("[RES RECLAIM] " + c + " (runq=0/8 swap=1%): adding lanes makes it worse")
else:
    print("OBJECTIVE ok")
EOF
  else
    # Default: a benign objective cache line, so the gate is a no-op here. It deliberately does NOT
    # contain the token `DO: ` — that token is §4's position anchor, and a stub may not plant one.
    printf '2026-01-01T00:00:00+00:00 x\nOBJECTIVE ok open=3 waiting=2 | ALLOW\n' \
      > "$h/.pi/agent/state/objective.last"
  fi
  if [ "$mode" = checker ]; then
    # Answers the capability probe with a help text that advertises `--surface` (the floor refuses a
    # checker that does not), then records the payload it was asked to send and returns VERIFIED.
    cat > "$h/.pi/agent/scripts/lib/cmux_payload.py" <<'EOF'
import os, sys
a = sys.argv[1:]
if not a or a[0] != "verify":
    sys.exit(2)
if "--help" in a:
    print("usage: verify --workspace W --surface S --text=T --timeout N")
    sys.exit(0)
txt = ""
for x in a:
    if x.startswith("--text="):
        txt = x[len("--text="):]
if not txt:
    sys.exit(2)
with open(os.path.join(os.environ["HOME"], "payload.txt"), "w") as fh:
    fh.write(txt)
print("VERIFIED")
EOF
  fi
}

# The floor is run from the WORKTREE with a literal relative path (a `bash "$VAR/…"` command-position
# path is refused by the script-indirection gate, #1228/#1893) and only `$HOME`/`PATH` are sandboxed.
floor_run(){ # floor_run <home> [<script>]
  ( cd "$ROOT" && HOME="$1" PATH="$1/bin:$PATH" bash "${2:-scripts/cadence-nudge.sh}" ) \
    >"$1/out.txt" 2>"$1/floor.err"
  return $?
}
err_of(){ tr '\n' ' ' < "$1/floor.err" 2>/dev/null | cut -c1-220; }

# Assert the delivered payload -- the bytes the pane would have received -- carries the order.
# This is the ONLY place the order is accepted as present; everything in §1-§3 is about the source.
delivery_check(){ # delivery_check <label> <home> <anchor-token>
  local name="$1" h="$2" anchor="$3" body="" p="$2/payload.txt" i_ord i_anc
  if [ ! -s "$p" ]; then
    fail "$name: the floor delivered NOTHING (no payload reached the egress) — every assertion below would be VACUOUS (stderr: $(err_of "$h"))"
    return 1
  fi
  body="$(cat "$p")"
  # The receipt is the floor's own record that it reached its send path rather than exiting early.
  if grep -qs 'NUDGE at=' "$h/.pi/agent/state/orchestrator-heartbeat.log"; then
    pass "$name: the floor wrote its own receipt (it reached the send path, not an early exit)"
  else
    fail "$name: no NUDGE receipt in the log — the floor exited before sending, so nothing here is pinned"
  fi
  if has "$body" "$FRAMING"; then
    pass "$name: the DELIVERED payload carries the order's framing"
  else
    fail "$name: the delivered payload LOST the order (framing absent) — this is the #1993 defect: the beat reports state and orders nothing"
  fi
  local i n
  for i in 0 1 2 3; do
    n="$(count_of "$body" "${ORDER[$i]}")"
    if [ "$n" = "1" ]; then
      pass "$name:   canonical sentence $((i + 1)) VERBATIM, exactly once"
    elif [ "$n" = "0" ]; then
      fail "$name:   canonical sentence $((i + 1)) MISSING or reworded in the DELIVERED payload"
    else
      fail "$name:   canonical sentence $((i + 1)) appears ${n}x — a duplicate append"
    fi
  done
  # T5/T6: the whole beat is ONE line. A payload carrying a real newline is delivered as several turns
  # (`cmux send` submits each newline), which is the owner-reported "many individual messages".
  local lines
  lines="$(printf '%s' "$body" | grep -c '' || true)"
  if [ "${lines:-0}" = "1" ]; then
    pass "$name: the payload is ONE line (cmux send would submit it as one turn)"
  else
    fail "$name: the payload holds ${lines:-?} lines — cmux send submits each newline as its own turn"
  fi
  # T4/placement: the order precedes the anchor — the DO: clause (or the act content when the recap is
  # present) whose `${prov}` marker stays next to the classes it qualifies. #1187 measured a 1,962-byte
  # payload arriving as its FIRST SENTENCE, so the order may not be the tail of a payload this long,
  # and it may not be folded into the clause the resource gate rewrites.
  i_ord="$(idx_of "$body" "$FRAMING")"
  i_anc="$(idx_of "$body" "$anchor")"
  if [ -n "$i_ord" ] && [ -n "$i_anc" ] && [ "$i_ord" -lt "$i_anc" ]; then
    pass "$name: the order precedes '${anchor}' (offset ${i_ord} < ${i_anc}) — behind the state header, not behind the gated clause"
  else
    fail "$name: the order does not precede '${anchor}' (order=${i_ord:-absent} anchor=${i_anc:-absent}) — it was moved behind the gated clause or to the tail"
  fi
  return 0
}

echo ""
echo "4. the wire: the order reaches the payload the floor actually hands over"
# 4a. the CHECKER arm — the path taken on a healthy box.
h="$TMP/checker"; sandbox "$h" checker
floor_run "$h"
delivery_check "checker" "$h" "CONTINUE lane-x"
if [ -s "$h/cmux-calls.txt" ] && has "$(cat "$h/cmux-calls.txt")" "send"; then
  fail "checker: a cmux send ran as well as the checker — a SECOND egress can carry a countermand"
else
  pass "checker: the checker was the only egress (no second send)"
fi
if grep -qs 'verdict=VERIFIED' "$h/.pi/agent/state/orchestrator-heartbeat.log"; then
  pass "checker: the receipt records verdict=VERIFIED (the verified path really ran)"
else
  fail "checker: the receipt does not record VERIFIED — this state did not exercise the checker arm"
fi

# 4b. the RAW arm — no usable checker, i.e. the broken box the floor exists for.
h="$TMP/raw"; sandbox "$h" raw
floor_run "$h"
delivery_check "raw" "$h" "CONTINUE lane-x"
if grep -qs 'verdict=NO-USABLE-CHECKER' "$h/.pi/agent/state/orchestrator-heartbeat.log"; then
  pass "raw: the receipt records NO-USABLE-CHECKER (the raw arm really ran)"
else
  fail "raw: the receipt does not record the no-checker verdict — this state did not exercise the raw arm"
fi
# The raw arm hands cmux `"$MSG\n"` — the message plus TWO literal characters. Asserted, because a
# payload that is not one message is the noise defect.
case "$(cat "$h/payload.txt")" in
  *'\n') pass "raw: the payload ends with the literal \\n the floor passes (one submitted message)" ;;
  *)     fail "raw: the payload does not end with the floor's \\n — the egress argv changed shape" ;;
esac

# 4c. the BARE state — no lane recap: the message the floor builds out of nothing. A clause keyed on
#     any recap input would be lost exactly here.
h="$TMP/bare"; sandbox "$h" raw bare
floor_run "$h"
delivery_check "bare" "$h" "DO: "
_bare="$(cat "$h/payload.txt" 2>/dev/null)"
if has "$_bare" "[PROVISIONAL"; then
  pass "bare: the degraded message really is the provisional one (this state is the fallback path)"
else
  fail "bare: no PROVISIONAL marker — this state did not take the fallback path, so it proves nothing new"
fi

# 4d. the RECLAIM state — a populated DO: clause AND a resource verdict of `DO: RECLAIM`, so the gate
#     neutralises the dispatch verb. The order must come through untouched AND ahead of it.
h="$TMP/reclaim"; sandbox "$h" raw recap reclaim
floor_run "$h"
delivery_check "reclaim" "$h" "[RES RECLAIM]"
_rec="$(cat "$h/payload.txt" 2>/dev/null)"
if has "$_rec" "[RES RECLAIM]"; then
  pass "reclaim: the resource gate really fired (the DO: clause was neutralised and says why)"
else
  fail "reclaim: the gate did NOT fire — this state proves nothing about the order surviving it"
fi
if has "$_rec" "CONTINUE lane-x"; then
  pass "reclaim: ...and the gated clause still carries the act content (the stub did not eat it)"
else
  fail "reclaim: the act clause vanished — the stub drifted, so the ordering assertion is vacuous"
fi
if has "$_rec" "${ORDER[1]}"; then
  pass "reclaim: USE THE CAPACITY DO NOT REPORT IT survives the gate VERBATIM (a standing order is not a dispatch offer)"
else
  fail "reclaim: the gate mangled the order — the clause was folded into the gated \${doact}"
fi

echo ""
echo "5. egress count: exactly one payload per run"
_n="$(grep -c 'send' "$TMP/raw/cmux-calls.txt" 2>/dev/null || true)"
if [ "${_n:-0}" = "1" ]; then
  pass "raw: exactly one cmux send invocation (no backgrounded or conditional second egress)"
else
  fail "raw: ${_n:-0} cmux send invocation(s), expected 1 — a second egress can carry a countermand"
fi

echo ""
echo "6. SENSITIVITY: the same driver must FAIL on a mutated floor"
# Each mutant is the shipped file with ONE deliberate edit. If any of them still passes §4's checks,
# those checks read something other than the delivered clause. The mutation lives in a QUOTED heredoc
# so bash cannot expand the very `$…` sequences it is rewriting (measured: an unquoted heredoc turned a
# `doact="$_g"` needle into `doact=""` and the mutant silently stopped applying).
mutate(){ # mutate <name>
  local name="$1"
  MUT="$TMP/mut-$name.sh"
  if ! /usr/bin/python3 - "$FLOOR" "$MUT" "$name" <<'PY'
import re, sys
src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
if name == "emptied":                       # T1: the order simply is not there
    text = re.sub(r'(?m)^FLEETADV_FLOOR=.*$', 'FLEETADV_FLOOR=""', text)
elif name == "gated":                       # T4: folded into the clause the resource gate governs
    before = text
    text = text.replace("${FLEETADV_FLOOR} ${prov}DO:", " ${prov}DO:", 1)
    # Appended to `doact` after its definition (bash is top-down, so a mutation above the definition
    # would just die on `set -u` and prove nothing about the ASSERTIONS). The order then rides the
    # DO: segment instead of the state header -- the shape §4's placement assertion exists for.
    text = text.replace('\nMSG="[HEARTBEAT', '\ndoact="${doact} ${FLEETADV_FLOOR}"\nMSG="[HEARTBEAT', 1)
    if text == before:
        sys.exit(3)
elif name == "reworded":                    # T3: one sentence reworded in place
    text = text.replace("A beat that reports state and dispatches nothing is a WASTED BEAT.",
                        "A beat that reports state is a useful beat even if it dispatches nothing.", 1)
elif name == "conditional":                 # T2: a gate around the assignment, keyed on a real input
    text = text.replace('MSG="[HEARTBEAT ${hms}] fleet ${fleet}. ${obj} ${res} ${FLEETADV_FLOOR}',
                        '[ -z "${_ract}" ] && MSG="[HEARTBEAT ${hms}] fleet ${fleet}. ${obj} ${res} ${FLEETADV_FLOOR}', 1)
else:
    sys.exit(4)
if text == open(src, encoding="utf-8").read():
    sys.exit(5)
open(dst, "w", encoding="utf-8").write(text)
PY
  then
    fail "mutant $name could not be built (the mutation did not apply) — the shipped file changed shape"
    return 1
  fi
  return 0
}

# M1 (T1): empty the clause. The order must disappear from the delivered payload.
if mutate emptied; then
  h="$TMP/m1"; sandbox "$h" raw
  floor_run "$h" "$MUT"
  _m="$(cat "$h/payload.txt" 2>/dev/null)"
  if [ -z "$_m" ]; then
    fail "emptied: the mutant produced no payload — the sensitivity check could not run"
  elif has "$_m" "$FRAMING" || has "$_m" "${ORDER[3]}"; then
    fail "emptied: the mutated floor STILL delivered the order — §4 is reading something other than the shipped clause"
  else
    pass "emptied: emptying the literal removes the order from the same driver (the assertions are live)"
  fi
fi

# M2 (T4): move the clause OUT of the state header and INTO the gated DO: segment. A reading of
# "present somewhere in the payload" passes this; the placement assertion must not.
if mutate gated; then
  h="$TMP/m2"; sandbox "$h" raw recap reclaim
  floor_run "$h" "$MUT"
  _m="$(cat "$h/payload.txt" 2>/dev/null)"
  _io="$(idx_of "$_m" "$FRAMING")"; _ia="$(idx_of "$_m" "[RES RECLAIM]")"
  if [ -z "$_m" ]; then
    fail "gated: the mutant produced no payload"
  elif has "$_m" "$FRAMING" && [ -n "$_io" ] && [ -n "$_ia" ] && [ "$_io" -gt "$_ia" ]; then
    pass "gated: folding the order into \${doact} puts it behind the gate's '[RES RECLAIM]' — the placement assertion catches it"
  else
    fail "gated: the mutant kept the order ahead of the gate (order=${_io:-absent} gate=${_ia:-absent}) — the placement assertion cannot see a fold into the gated clause"
  fi
fi

# M3 (T3): reword one sentence in place. A presence-only pin on the framing passes this; the verbatim
# assertion must not.
if mutate reworded; then
  h="$TMP/m3"; sandbox "$h" raw
  floor_run "$h" "$MUT"
  _m="$(cat "$h/payload.txt" 2>/dev/null)"
  if [ -z "$_m" ]; then
    fail "reworded: the mutant produced no payload"
  elif has "$_m" "${ORDER[3]}"; then
    fail "reworded: the mutation did not take effect (the canonical closing sentence is still delivered)"
  else
    pass "reworded: a reworded closing sentence is caught (the delivered text is compared verbatim)"
  fi
fi

# M4 (T2): gate the assignment on an input that is non-empty only in the RECLAIM state, so the order is
# lost exactly where the gate fires — the classic "conditional at the definition" shape.
if mutate conditional; then
  h="$TMP/m4"; sandbox "$h" raw recap reclaim
  floor_run "$h" "$MUT"
  _m="$(cat "$h/payload.txt" 2>/dev/null)"
  if [ -z "$_m" ]; then
    fail "conditional: the mutant produced no payload"
  elif has "$_m" "$FRAMING"; then
    fail "conditional: a gate around the assignment still delivered the order — the mutation did not take"
  else
    pass "conditional: gating the MSG assignment on a resource-derived input loses the order in that state, and §4d sees it"
  fi
fi

echo ""
# ⛔ THE FLOOR ON THE ASSERTION COUNT, SET TO THE SHIPPED COUNT EXACTLY. A lower number leaves slack in
# which a whole guard can be deleted while the suite still reports green; at the exact count any
# removal is red. Adding assertions is safe — removing one means lowering this deliberately.
MIN_CHECKS=62
if [ "$checks" -lt "$MIN_CHECKS" ]; then
  fail "only $checks assertions ran, below the shipped floor of $MIN_CHECKS — a check was removed"
fi
echo ""
echo "Residuals (stated, not implied): an edit keyed on a COMBINATION of states these four do not visit is"
echo "not caught. A rewrite that both files carry identically is caught only by §1's fixed canonical text —"
echo "editing the order is a deliberate act, and that is the assertion it must pay. The floor's own delivery"
echo "VERDICT (#1187/#3795: a payload can be verified as sent yet arrive truncated) is out of scope: this"
echo "suite pins what the floor HANDS OVER, which is the precondition that verdict needs."
if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-floor-advance suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-floor-advance suite: $failures of $checks assertion(s) failed"
exit 1
