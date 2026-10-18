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
# WHAT THIS SUITE PINS, AND WHY IT IS ONE ASSERTION PER SENTENCE
# --------------------------------------------------------------
#   The order lives in the script as FOUR SENTENCES (`FA1`..`FA4`), defined once and embedded
#   VERBATIM in both bodies; the alert body adds only the (1)(2)(3) numbering and one
#   elaboration. So this suite asserts each sentence is present VERBATIM in the DELIVERED
#   quiet beat and in the DELIVERED alert beat.
#
#   That shape is deliberate, and it is the lesson of three review rounds: a suite that pins
#   a LIST OF PHRASES is never exhaustive — each round produced a new "delete this word and
#   stay green" mutant (the AUTOPILOT gloss, the "three cloud VMs", "name this cycle's PRs",
#   "cmux", the order-2 mapping, the order-3 tail). A marker per phrase cannot be complete;
#   an assertion that the WHOLE INSTRUCTION is present can. A deletion, a reword or a
#   softening inside any of the four sentences is red, on either body.
#
# Sections:
#   0. WIRING + FORMATION — the sentences and both bodies are defined exactly once; FA1..FA4
#      carry no backtick, double quote or `$`; the composed bodies reference ONLY ${FA1}..${FA4};
#      each append sits where it belongs. (`MSG` is a DOUBLE-QUOTED assignment, so a backticked
#      span is command-substituted at assignment time and the text silently vanishes — the
#      failure mode is a hole in the shipped beat that the file on disk still looks right about.)
#   1. THE QUIET BEAT — the SHORT FORM / PULSE body, with EVERY conditional clause empty,
#      carries all four sentences verbatim. That is the unconditionality proof: nothing but an
#      unconditional append could have put them there. The alert body's elaboration must be
#      ABSENT here (that is what makes the two bodies distinguishable at runtime).
#   2. THE FULL BEAT — the alert body (built before the short-form overwrite) carries the same
#      four sentences verbatim, plus the elaboration.
#   3. PROPORTIONALITY — the quiet beat is genuinely the shorter body, and the SHORT wording is
#      under a FIXED ceiling (never one derived from the variant under test, which would relax
#      itself as the text grows).
#   4. SENSITIVITY — the same driver against a mutant whose sentences are emptied must LOSE the
#      clause, so a driver that never reached the fragment cannot report a permanent green.
#
# ⛔ THE EXPECTED SENTENCES ARE FIXED STRINGS IN THIS FILE, NEVER READ FROM THE SCRIPT UNDER TEST.
# The first cut of this suite derived its expectations from the shipped `FA1`..`FA4`, which made the
# whole thing VACUOUS: a mutant that reworded or deleted an instruction was compared against its own
# mutated text and passed (verified: five such mutants all went green). An expectation that comes
# from the artifact cannot fail on the artifact. The canonical order is therefore restated below,
# from issue #1991 — deliberately, so that changing what the beat orders means changing this file
# too, which is exactly the review the owner's instruction should get.
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
# assertion, i.e. exactly backwards. Case globs have no upstream writer to race with.
# `hasi` lowercases the haystack: the shipped text may shout, the assertion may not care.
hasi(){ case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "0. the clause under test is the SHIPPED one"
if [ ! -f "$HB" ]; then
  echo "❌ heartbeat-fleet-advance suite: $HB not found"; exit 1
fi
# The four order sentences, read from the SHIPPED source — not restated here, or this suite
# would drift from the text it claims to pin. `text_of` returns the assignment's value.
text_of(){ sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$HB" | head -1; }
for _v in FA1 FA2 FA3 FA4 FLEETADV FLEETADV_SHORT; do
  case "$(sed -n "s/^$_v=\"\\(.*\\)\"$/\\1/p" "$HB" | wc -l | tr -d ' ')" in
    1) pass "$_v is defined exactly once" ;;
    *) fail "$_v must be defined exactly once (found $(sed -n "s/^$_v=\".*\$/X/p" "$HB" | wc -l | tr -d ' ')) — two copies diverge" ;;
  esac
done
# EXECUTABLE position: comments stripped BEFORE counting, so a clause that survives only in a
# comment (or was deleted) fails here rather than being "found" in the prose that explains it.
_live_hits="$(sed 's/#.*//' "$HB" | grep -c 'FLEETADV' || true)"
if [ "${_live_hits:-0}" -ge 2 ]; then
  pass "the clause is referenced in executable position (${_live_hits} sites, not only in comments)"
else
  fail "FLEETADV is absent or commented out in orchestrator-heartbeat.sh — the order would never ship"
  echo "❌ heartbeat-fleet-advance suite: the clause is not wired"; exit 1
fi
# FORMATION. Each SENTENCE must be a single double-quoted literal with nothing inside that bash
# would interpret: no `"` (terminates the literal early), no backtick (command substitution), no
# `$` (expansion). The composed bodies are exempt only for their ${FA1}..${FA4} references.
for _v in FA1 FA2 FA3 FA4; do
  _in="$(text_of "$_v")"
  case "$_in" in
    *'"'*) fail "$_v contains a double quote — it would terminate the literal early" ;;
    *'`'*) fail "$_v contains a backtick — bash would command-substitute it away at assignment" ;;
    *'$'*) fail "$_v contains a dollar sign — bash would expand it at assignment" ;;
    '')    fail "$_v is EMPTY — that instruction would vanish from both bodies" ;;
    *)     pass "$_v is one self-contained literal (${#_in} chars, no quotes/backticks/\$)" ;;
  esac
done
for _v in FLEETADV FLEETADV_SHORT; do
  _raw="$(text_of "$_v")"
  _rest="$(printf '%s' "$_raw" | sed 's/\${FA[1-4]}//g')"
  case "$_rest" in
    *'$'*) fail "$_v contains a \$-reference other than \${FA1}..\${FA4} — bash would expand it" ;;
    *'`'*) fail "$_v contains a backtick — bash would command-substitute it away at assignment" ;;
    *'"'*) fail "$_v contains a double quote — it would terminate the literal early" ;;
    *)     if hasi "$_raw" '${fa1}' && hasi "$_raw" '${fa2}' && hasi "$_raw" '${fa3}' && hasi "$_raw" '${fa4}'; then
             pass "$_v is composed of \${FA1}..\${FA4} and nothing bash would interpret"
           else
             fail "$_v does not embed all four order sentences — a body would miss an instruction"
           fi ;;
  esac
done
# PLACEMENT. The full-body append must be a column-0 statement (an indented one lives inside an
# `if`, which would make the order conditional); the short-form append must be indented, i.e.
# inside the short-form branch, because that is the ONLY place a quiet beat passes through. The
# unconditionality itself is proven behaviourally in §1, not by this indentation read.
_full_use="$(sed -n 's/^MSG="\${MSG} \${FLEETADV}"$//p' "$HB" | wc -l | tr -d ' ')"
_short_use="$(sed -n 's/^  MSG="\${MSG} \${FLEETADV_SHORT}"$//p' "$HB" | wc -l | tr -d ' ')"
if [ "${_full_use:-0}" = "1" ] && [ "${_short_use:-0}" = "1" ]; then
  pass "the alert body appends FLEETADV and the short-form branch appends FLEETADV_SHORT"
else
  fail "the two bodies are not wired as intended (full-body uses=${_full_use:-0}, short-form uses=${_short_use:-0})"
fi

echo ""
# ── the driver ───────────────────────────────────────────────────────────────────────
# A SANDBOXED FULL TICK, not an extraction of the MSG lines: the message is whatever the
# script actually SENDS. Everything the tick reaches for is a stub under $HOME (its own
# resolution root — SCRIPTS/STATE/SD all come from $HOME), plus a `cmux` on $PATH that
# records the send. Nothing here touches real fleet state, and no network is used.
#
# The `ask` knob selects the two message bodies:
#   ask=0  every conditional input empty -> the QUIET/PULSE path -> the SHORT FORM
#   ask=1  a routed question             -> the alert body (built BEFORE the short-form overwrite)
sandbox(){ # sandbox <dir> <ask:0|1>
  local h="$1" ask="$2"
  mkdir -p "$h/.pi/agent/scripts" "$h/.pi/agent/state" "$h/.pi/agent/sessions/s1" "$h/bin"
  # The registry only has to be READABLE (the tick exits early without it) — its content is
  # never the subject of this suite.
  printf 'lane\tws\tsid\n' > "$h/.pi/agent/state/lane-registry.tsv"
  # Every helper the tick calls, answered offline. `pass=0` / `count=0` / no VERDICT= keep every
  # conditional clause EMPTY, which is what makes §1 a proof of unconditionality.
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

# The canonical order, restated from #1991. FIXED on purpose — see the header. A change here is a
# change to what the fleet is ordered to do, and must be deliberate.
ORDER=(
  "CHECK THE cmux LANES AND ALL FOUR BOXES (local + the three cloud VMs) and push each toward AUTOPILOT — dispatching, creating PRs, fixing them, merging them UNATTENDED."
  "USE THE CAPACITY, DO NOT REPORT IT: dispatch locally if the local machine has room, on a cloud VM if it is idle."
  "DRIVE THE P0/P1 PRs: name the specific PRs that should land this cycle, take each one to the rail via scripts/admin-merge.sh, and advance agent-infra (cell-2 owns it) toward automating dispatch, PR creation, fixing and merging."
  "A beat that reports state and dispatches nothing is a WASTED BEAT."
)
# ...and the shipped sentences must BE those, not merely resemble them: a reworded instruction is a
# different instruction, and the layer that can silently reword it is the one this suite exists for.
for i in 0 1 2 3; do
  _shipped="$(text_of "FA$((i + 1))")"
  if [ "$_shipped" = "${ORDER[$i]}" ]; then
    pass "FA$((i + 1)) in the shipped script is the canonical sentence, verbatim"
  else
    fail "FA$((i + 1)) does not match the canonical sentence — the order was reworded or edited: got '${_shipped:0:90}...'"
  fi
done
_elab="paragraph about load"            # the alert body's elaboration, full-only by construction
_ceiling=700                            # fixed ceiling on the SHORT wording's length, in chars

echo "1. a QUIET beat (short form) carries the order — with every conditional clause EMPTY"
h="$TMP/quiet"; sandbox "$h" 0
quiet="$(beat "$h" "$HB")"
if [ -z "$quiet" ]; then
  fail "the quiet beat produced NO message — the tick exited before sending (guard changed?)"
else
  if hasi "$quiet" "no alerts."; then
    pass "the quiet beat really is the SHORT form (the body that rebuilds MSG)"
  else
    fail "the quiet beat was not the short form — §1 would not be testing the rebuild path"
  fi
  # Nothing conditional had anything to say: no alerts, no questions, no capacity, no
  # dead/occupied lanes, no merge-queue or objective verdict. The order cannot have arrived
  # from any of them, so its presence here IS the unconditionality proof.
  if hasi "$quiet" "capacity:" || hasi "$quiet" "dead lanes" || hasi "$quiet" "no live pi record" \
     || hasi "$quiet" "merge-queue bottleneck" || hasi "$quiet" "questions:"; then
    fail "the quiet sandbox emitted a conditional clause — §1 would not prove unconditionality"
  else
    pass "no conditional clause fired in the quiet beat (only an unconditional append could add it)"
  fi
  for i in 0 1 2 3; do
    if hasi "$quiet" "$(printf '%s' "${ORDER[$i]}" | tr '[:upper:]' '[:lower:]')"; then
      pass "  quiet beat carries canonical sentence $((i + 1)) VERBATIM"
    else
      fail "  quiet beat is MISSING (or has reworded) canonical sentence $((i + 1)): ${ORDER[$i]}"
    fi
  done
  # The alert body's elaboration must not be here — it is what makes the two bodies different,
  # and a quiet beat that carries it is the full text on the pulse path.
  if hasi "$quiet" "$_elab"; then
    fail "the quiet beat carries the alert body's elaboration ('$_elab') — the LONG variant rode it"
  else
    pass "the quiet beat omits the alert-only elaboration (it carries the short body)"
  fi
fi

echo ""
echo "2. the FULL beat (a routed question) carries the same four sentences, verbatim"
h="$TMP/full"; sandbox "$h" 1
full="$(beat "$h" "$HB")"
if [ -z "$full" ]; then
  fail "the full beat produced NO message — the tick exited before sending (guard changed?)"
else
  if hasi "$full" "needing attention."; then
    pass "the question beat really is the FULL form (its own body, built before the overwrite)"
  else
    fail "the question beat did not take the full-form path — the alert body is unpinned"
  fi
  for i in 0 1 2 3; do
    if hasi "$full" "$(printf '%s' "${ORDER[$i]}" | tr '[:upper:]' '[:lower:]')"; then
      pass "  full beat carries canonical sentence $((i + 1)) VERBATIM"
    else
      fail "  full beat is MISSING (or has reworded) canonical sentence $((i + 1)): ${ORDER[$i]}"
    fi
  done
  if hasi "$full" "$_elab"; then
    pass "the full beat carries its elaboration ('$_elab')"
  else
    fail "the full beat lost its elaboration — the alert body is carrying the short variant"
  fi
fi

echo ""
echo "3. proportionality: the quiet body is the SHORTER one, and the short wording is bounded"
if [ -n "$quiet" ] && [ -n "$full" ]; then
  if [ "${#quiet}" -lt "${#full}" ]; then
    pass "the quiet beat is shorter than the alert beat (${#quiet} < ${#full} chars)"
  else
    fail "the quiet beat (${#quiet}) is not shorter than the alert beat (${#full}) — bodies are swapped"
  fi
else
  fail "proportionality could not be measured — one of the two beats was not produced"
fi
# The RENDERED length of the short wording: the source line is mostly ${FA1}..${FA4} references, so
# substituting them here (plain parameter expansion — never `eval`) is what makes the ceiling a bound
# on the text a lane actually reads. The substituted values are read from the shipped source too.
_rend="$(text_of FLEETADV_SHORT)"
for _i in 1 2 3 4; do
  _val="$(text_of "FA$_i")"
  _rend="${_rend//"\${FA$_i}"/$_val}"
done
_short_text="$_rend"
if [ "${#_short_text}" -lt "$_ceiling" ]; then
  pass "the SHORT wording is under the fixed ${_ceiling}-char ceiling (${#_short_text} chars)"
else
  fail "the SHORT wording is ${#_short_text} chars, over the fixed ${_ceiling}-char ceiling — it has grown into the full text"
fi

echo ""
echo "4. SENSITIVITY: the same driver against a mutant of the shipped script must FAIL"
# The mutant empties the four SENTENCES and nothing else (the composed bodies remain), so the only
# difference in the delivered beat is the order. If the sentences still appear, this suite is
# reading something other than the shipped clause and would be permanently green.
MUT="$TMP/mutant.sh"
/usr/bin/python3 - "$HB" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out = []
for ln in open(src, encoding="utf-8").read().splitlines(True):
    # Blank the four sentences AND both composed bodies: the header text alone would otherwise keep
    # the words "FLEET ADVANCE" in the message and mask a driver that never reached the clause.
    hit = ln.startswith(("FA1=", "FA2=", "FA3=", "FA4=", "FLEETADV=", "FLEETADV_SHORT="))
    out.append(ln.split("=")[0] + '=""\n' if hit else ln)
open(dst, "w", encoding="utf-8").writelines(out)
PY
h="$TMP/mutant"; sandbox "$h" 0
out="$(beat "$h" "$MUT")"
if [ -z "$out" ]; then
  fail "the MUTANT produced no message — the sensitivity check could not run, so nothing is pinned"
elif hasi "$out" "fleet advance"; then
  fail "the MUTANT still carried the clause — the assertions above are not reading the shipped text"
else
  pass "emptying the four sentences removes the clause from the same driver (assertions are sensitive)"
fi

echo ""
# ⛔ A FLOOR ON THE ASSERTION COUNT, SET TO THE SHIPPED COUNT EXACTLY. A lower number leaves slack in
# which a single-check guard — this mutant, one formation rule, one sentence — can be deleted while
# the suite still reports green (measured in review: 30-of-36 absorbed three such deletions). At the
# exact count any removal is red. Adding assertions is safe; REMOVING one means lowering this number
# deliberately, which is the point.
MIN_CHECKS=34
if [ "$checks" -lt "$MIN_CHECKS" ]; then
  fail "only $checks assertions ran, below the shipped floor of $MIN_CHECKS — a check was removed"
fi
if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-fleet-advance suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-fleet-advance suite: $failures of $checks assertion(s) failed"
exit 1
