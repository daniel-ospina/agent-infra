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
# ── HOW THIS SUITE IS BUILT (read before changing it) ────────────────────────────────
#   Seven review rounds produced the same finding in different clothes: an assertion that
#   pins a LOWER BOUND ("the four sentences are present") cannot fail on text that is ADDED,
#   and one that pins a SAMPLE of the state space ("the quiet beat with an empty fleet")
#   cannot fail on an edit keyed on a state it never visits. Every round's green mutant was
#   one of those two shapes. So this suite pins EXACTNESS and EXACTNESS-PER-STATE:
#
#     * the four order sentences are FIXED in this file (never read from the script under
#       test — an expectation taken from the artifact cannot fail on it), and the shipped
#       FA1..FA4 must EQUAL them;
#     * both composed bodies are pinned to their exact documented text, so nothing can be
#       added to, reordered in, or reworded in either one;
#     * the delivered beat is pinned BY LENGTH in EIGHT states covering every gate the tick
#       has (no lanes / one working lane / working+waiting-child / idle capacity / a routed
#       question / an alerting lane / a merge-queue bottleneck / an objective at risk), and
#       each must carry the four sentences exactly once. A body that gains or loses any text
#       in any of those states is red;
#     * ordering is checked where the comment claims it: in the capacity state the order is
#       immediately followed by the CAPACITY clause, and in the plain pulse states the order
#       is the LAST thing in the beat;
#     * a coarse static lint counts statements that touch the order or MSG. It catches a NEW
#       statement (an added append, an `eval`, a `printf -v MSG`); it says nothing about text
#       added inside an existing literal — that is the exact-length pins' job. The lint is
#       labelled as a lint on purpose: two rounds were spent on a count that claimed to prove
#       more than a count can.
#     * a mutant of the shipped script must LOSE the clause through the same driver, so a
#       driver that never reached the fragment cannot report a permanent green.
#
#   ⛔ THE EXPECTED SENTENCES AND THE EXPECTED LENGTHS ARE FIXED STRINGS IN THIS FILE. The
#   canonical order is restated from issue #1991 deliberately: changing what the beat orders
#   means changing this file too, which is the review the owner's instruction should get.
#   ⛔ THE LENGTHS ARE BYTES. `${#x}` counts characters in a UTF-8 locale and bytes in the C
#   locale, and the order text carries exactly the characters that differ (⛔, —), so the
#   locale is pinned below and every number here means bytes.
#
# Run: bash tests/heartbeat-fleet-advance/run.sh
set -uo pipefail
export LC_ALL=C LANG=C

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HB="${HB_OVERRIDE:-$ROOT/scripts/orchestrator-heartbeat.sh}"

checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }
# ⛔ A SUBSTRING TEST THAT IS NOT THE SIGPIPE IDIOM (#841/#864): a `printf … | grep -q` here
# would race under pipefail and can take the `else` branch — reporting PASS on a WITHHOLDING
# assertion, i.e. exactly backwards. Case globs have no upstream writer to race with.
# `hasi` lowercases the HAYSTACK only, so every needle passed to it must be lowercase.
hasi(){ case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# `count_of` — how many times a needle occurs. Not a quiet grep: `grep -o` writes to the pipe,
# so there is no SIGPIPE race under `pipefail`, and an exact count is what makes "the order
# appears twice" (a duplicate append inflating every beat) a red instead of a pass.
count_of(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | grep -o -F "$2" | wc -l | tr -d ' '; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "0. the clause under test is the SHIPPED one"
if [ ! -f "$HB" ]; then
  echo "❌ heartbeat-fleet-advance suite: $HB not found"; exit 1
fi
# `text_of` returns an assignment's VALUE from the shipped script. It feeds the FORMATION
# checks, the "defined exactly once" check and the rendered-length ceiling — it is NEVER the
# source of the CONTENT expectation, which is the fixed `ORDER` array below.
text_of(){ sed -n "s/^$1=\"\\(.*\\)\"$/\\1/p" "$HB" | head -1; }
for _v in FA1 FA2 FA3 FA4 FLEETADV FLEETADV_SHORT; do
  case "$(sed -n "s/^$_v=\"\\(.*\\)\"$/\\1/p" "$HB" | wc -l | tr -d ' ')" in
    1) pass "$_v is defined exactly once" ;;
    *) fail "$_v must be defined exactly once (found $(sed -n "s/^$_v=\".*\$/X/p" "$HB" | wc -l | tr -d ' ')) — two copies diverge" ;;
  esac
done
# ── a coarse statement lint (see the header: a lint, not a proof) ─────────────────────
# ⛔ THE COMMENT STRIP REMOVES FULL-LINE COMMENTS ONLY. `sed 's/#.*//'` truncates at the first
# `#` anywhere, and this file legitimately expands `${QUEUE#QUEUE: }` and `${LOG##*/}` — an
# earlier version of this check stripped those lines and silently stopped counting them.
_nc="$(sed 's/^[[:space:]]*#.*//' "$HB")"
_lint_appends="$(printf '%s' "$_nc" | grep -o 'MSG="\${MSG}' | wc -l | tr -d ' ')"
_lint_assigns="$(printf '%s' "$_nc" | grep -o 'MSG=' | wc -l | tr -d ' ')"
_lint_msg_lines="$(printf '%s\n' "$_nc" | grep -c 'MSG' || true)"
_lint_order_lines="$(printf '%s\n' "$_nc" | grep -cE '(FA[1-4]|FLEETADV)' || true)"
# Shipped: 9 appends of the form MSG="${MSG} …", 12 MSG= occurrences in all (the extra three
# are the two bodies' initial `MSG="[HEARTBEAT …` and the append chain's `MSG="$MSG …`), 13
# executable lines mentioning MSG (12 assignments + the send), 8 lines touching the order.
lint(){ # lint <label> <got> <want>
  if [ "$2" = "$3" ]; then
    pass "lint: $1 = $3 (an added statement would change it)"
  else
    fail "lint: $1 is now $2 (expected $3) — a statement was added or removed; if deliberate, update this number in §0 of tests/heartbeat-fleet-advance/run.sh and say why in the commit message"
  fi
}
lint 'MSG="${MSG} …" appends' "$_lint_appends" 9
lint 'MSG= occurrences (anywhere in a line)' "$_lint_assigns" 12
lint 'executable lines mentioning MSG' "$_lint_msg_lines" 13
lint 'executable lines touching the order' "$_lint_order_lines" 8
# EXECUTABLE position: exactly two APPEND sites reference the composed bodies (a count of the
# word FLEETADV is satisfied by the definition lines alone — measured in review).
_live_hits="$(printf '%s\n' "$_nc" | grep -cE '^[[:space:]]*MSG="\$\{MSG\} \$\{FLEETADV(_SHORT)?\}"' || true)"
if [ "${_live_hits:-0}" -ge 2 ]; then
  pass "the order is appended in executable position at ${_live_hits} sites (not only in comments)"
else
  fail "the order is not appended at both bodies (found ${_live_hits:-0} append site(s)) — the order would never ship"
  echo "❌ heartbeat-fleet-advance suite: the clause is not wired"; exit 1
fi
# FORMATION. Each SENTENCE must be a single double-quoted literal with nothing inside that bash
# would interpret: no `"` (terminates the literal early), no backtick (command substitution), no
# `$` (expansion). MSG is a DOUBLE-QUOTED assignment, so a backticked span is substituted away
# at assignment time and the file on disk still looks right about it.
for _v in FA1 FA2 FA3 FA4; do
  _in="$(text_of "$_v")"
  case "$_in" in
    *'"'*) fail "$_v contains a double quote — it would terminate the literal early" ;;
    *'`'*) fail "$_v contains a backtick — bash would command-substitute it away at assignment" ;;
    *'$'*) fail "$_v contains a dollar sign — bash would expand it at assignment" ;;
    '')    fail "$_v is EMPTY — that instruction would vanish from both bodies" ;;
    *)     pass "$_v is one self-contained literal (${#_in} bytes, no quotes/backticks/\$)" ;;
  esac
done
for _v in FLEETADV FLEETADV_SHORT; do
  _raw="$(text_of "$_v")"
  _rest="$(printf '%s' "$_raw" | sed 's/\${FA[1-4]}//g')"
  case "$_rest" in
    *'$'*) fail "$_v contains a \$-reference other than \${FA1}..\${FA4} — bash would expand it" ;;
    *'`'*) fail "$_v contains a backtick — bash would command-substitute it away at assignment" ;;
    *'"'*) fail "$_v contains a double quote — it would terminate the literal early" ;;
    *)     pass "$_v contains nothing bash would interpret beyond its \${FA1}..\${FA4} references" ;;
  esac
done
# COMPOSITION, EXACTLY. "The variant carries the four sentences" permits ADDITION: a clause
# appended to one body only shipped in every quiet beat with an earlier suite green. The design
# says a variant may differ ONLY by elaboration, so both bodies are pinned to their FULL exact
# text — header, sentences, separators and the alert-only elaboration — and nothing else.
_elab_expected="Lanes must be running on real work, not described in a paragraph about load."
_EXPECT_SHORT='⛔ FLEET ADVANCE — an ORDER, not a report. ${FA1} ${FA2} ${FA3} ${FA4} '
_EXPECT_FULL="⛔ FLEET ADVANCE — an ORDER, not a report. (1) \${FA1} (2) \${FA2} ${_elab_expected} (3) \${FA3} \${FA4} "
for _pair in "FLEETADV:$_EXPECT_FULL" "FLEETADV_SHORT:$_EXPECT_SHORT"; do
  _name="${_pair%%:*}"; _want="${_pair#*:}"
  if [ "$(text_of "$_name")" = "$_want" ]; then
    pass "$_name is EXACTLY its documented composition (no added clause, no reordering, no rephrase)"
  else
    fail "$_name differs from its documented composition — a variant may differ only by elaboration (got: $(text_of "$_name"))"
  fi
done
# PLACEMENT. The alert body's append must be a standalone statement at column 0 (an indented
# one lives inside an `if`, making the order conditional), and the short-form append must be
# indented, i.e. inside the short-form branch — the only place a quiet beat passes through.
# The unconditionality itself is proven behaviourally in §1-§3, not by this indentation read.
# Comments are stripped FIRST: appending a trailing comment to either line is a legitimate
# documentation edit and must not red this check (measured false block).
_full_use="$(printf '%s\n' "$_nc" | grep -cE '^MSG="\$\{MSG\} \$\{FLEETADV\}"$' || true)"
_short_use="$(printf '%s\n' "$_nc" | grep -cE '^  MSG="\$\{MSG\} \$\{FLEETADV_SHORT\}"$' || true)"
if [ "${_full_use:-0}" = "1" ] && [ "${_short_use:-0}" = "1" ]; then
  pass "the alert body appends FLEETADV at column 0 and the short-form branch appends FLEETADV_SHORT"
else
  fail "the appends are not where they must be (alert-body append at column 0 found ${_full_use:-0}x, short-form append inside its branch found ${_short_use:-0}x) — an indented alert append is conditional, a column-0 short append is outside the branch"
fi

echo ""
# ── the driver ───────────────────────────────────────────────────────────────────────
# A SANDBOXED FULL TICK, not an extraction of the MSG lines: the message is whatever the
# script actually SENDS. Everything the tick reaches for is a stub under $HOME (its own
# resolution root — SCRIPTS/STATE/SD all come from $HOME), plus a `cmux` on $PATH that
# records the send. Nothing here touches real fleet state, and no network is used.
sandbox(){ # sandbox <dir> <ask:0|1> [lanes:empty|busy|wait|cap|alert] [mq:none|bottleneck] [obj:ok|risk]
  local h="$1" ask="$2" lanes="${3:-empty}" mq="${4:-none}" obj="${5:-ok}"
  # ⛔ `ws` IS COMPUTED BEFORE THE `case` THAT USES IT. The capacity row is built with the
  # orchestrator's own workspace id (the fake `cmux sessions list` reports it as live), and an
  # earlier version assigned it after the row was built — so the suite worked only because
  # §1 happened to run first, and a reordered section died with `unbound variable`.
  local ws; ws="$(sed -n 's/^ORCH_WS="\(.*\)"$/\1/p' "$HB")"
  mkdir -p "$h/.pi/agent/scripts" "$h/.pi/agent/state" "$h/.pi/agent/sessions/s1" "$h/bin"
  # The registry only has to be READABLE (the tick exits early without it) — its content is
  # never the subject of this suite.
  printf 'lane\tws\tsid\n' > "$h/.pi/agent/state/lane-registry.tsv"
  # Every helper the tick calls, answered offline. The default stub strings are part of the
  # GOLDEN: the delivered beats are pinned by length, so changing one changes §1's numbers.
  printf '#!/usr/bin/env python3\nprint("ASK pass=0 bounce=%s answered=0 scan_failed=0")\n' \
    "$ask" > "$h/.pi/agent/scripts/ask-owner.py"
  printf '#!/usr/bin/env python3\nprint("count=0")\n' > "$h/.pi/agent/scripts/undelivered-answers.py"
  printf '#!/usr/bin/env python3\nprint("DELIVERY 12 open PRs, 8 merged today, 8 P0/P1 PRs blocked")\n' \
    > "$h/.pi/agent/scripts/beta-progress.py"
  case "$mq" in
    bottleneck) printf '#!/usr/bin/env python3\nprint("QUEUE: 31 open VERDICT=BOTTLENECK")\n' ;;
    *)          printf '#!/usr/bin/env python3\nprint("QUEUE: 12 open, no verdict")\n' ;;
  esac > "$h/.pi/agent/scripts/merge-queue.py"
  case "$obj" in
    risk) printf '#!/usr/bin/env python3\nprint("OBJECTIVE VERDICT=FIX-MAIN main=red@abc123")\n' ;;
    *)    printf '#!/usr/bin/env python3\nprint("OBJECTIVE ok")\n' ;;
  esac > "$h/.pi/agent/scripts/objective.py"
  # The fleet view: `lane-status.py` is the ONLY source of N_TOTAL / N_ACT / N_WAIT / N_ALERT.
  case "$lanes" in
    busy)  _rows='[{"lane":"cell-2","ws":"s1","verdict":"WORKING"}]' ;;
    wait)  _rows='[{"lane":"cell-2","ws":"s1","verdict":"WORKING"},{"lane":"5","ws":"w5","verdict":"WAITING-CHILD","child":{"age":1200}}]' ;;
    # an idle lane with a LIVE pi record and no child: the CAPACITY clause fires
    cap)   _rows='[{"lane":"2a","ws":"'"$ws"'","verdict":"DONE-IDLE","stale_s":3600}]' ;;
    # EMPTY/UNBOUND are in NURT but not WEAK, so no screen is attempted and the alert fires
    alert) _rows='[{"lane":"2b","ws":"w2","verdict":"EMPTY"}]' ;;
    *)     _rows='[]' ;;
  esac
  printf '#!/usr/bin/env python3\nimport json,sys\njson.dump(%s, sys.stdout)\n' \
    "$_rows" > "$h/.pi/agent/scripts/lane-status.py"
  chmod +x "$h/.pi/agent/scripts"/*.py
  # `cmux` — the orchestrator pane must report a live pi (else the liveness guard withholds the
  # send), the pane must not look mid-turn (else the idle guard withholds it), and `send` is
  # recorded verbatim into the session file the tick then greps to verify its own delivery.
  # ⛔ THE MATCH IS ON THE FIRST TWO WORDS AND EVERYTHING ELSE IS LOGGED. Matching only `$1`
  # meant `cmux sessions kill …` was modelled as a read and the beat still went out green.
  cat > "$h/bin/cmux" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "sessions list") echo "workspace=$ws pid_exists=yes label=orchestrator" ;;
  "read-screen --workspace") echo "  idle at the prompt" ;;
  "send "*) _last=""; for _a in "\$@"; do _last="\$_a"; done
        printf '%s' "\$_last" >> "\$HOME/.pi/agent/sessions/s1/hb-11111111-1111-1111-1111-111111111111.jsonl" ;;
  "surface resume") echo "--session' '11111111-1111-1111-1111-111111111111'" ;;
  *) printf '%s\n' "\$*" >> "\$HOME/.pi/agent/stub-unhandled.log" ;;
esac
exit 0
EOF
  chmod +x "$h/bin/cmux"
}
beat(){ # beat <home> <script> -> the message the tick SENT
  # ⛔ BOUNDED: the tick polls its own delivery 20x5s when the recorded send does not verify, so
  # a stub drift would cost ~100s per beat instead of a red. 120s is far above the observed ~1s.
  timeout 120 env HOME="$1" PATH="$1/bin:$PATH" bash "$2" >"$1/tick.log" 2>&1
  # A cmux sub-command this fixture does not model means the tick depended on something nobody
  # stubbed: its answer is empty, which can read as a healthy empty fleet. Fail loudly, not green.
  if [ -s "$1/.pi/agent/stub-unhandled.log" ]; then
    fail "the tick called cmux sub-commands the fixture does not model: $(tr '\n' ';' < "$1/.pi/agent/stub-unhandled.log") — stub them before trusting this run"
  fi
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

# Exact delivered-body lengths, in BYTES, per state. Each is a GOLDEN of the beat in that state:
# changing any text the beat carries (ROLE, MAP, PRIORITY, a stub string, or the order) changes
# one of these, and the failure names the state and tells you to update it deliberately. The
# `+2` in every number is the tick's own trailing `\n` recorded literally by the cmux stub.
declare -A EXPECT_LEN=(
  [quiet]=1610 [busy]=1610 [wait]=1610 [cap]=1849
  [question]=4355 [alert]=3884 [bottleneck]=4380 [objective]=4391
)
order_check(){ # order_check <state> <delivered>
  local name="$1" body="$2" i n ok=1
  for i in 0 1 2 3; do
    n="$(count_of "$body" "$(printf '%s' "${ORDER[$i]}" | tr '[:upper:]' '[:lower:]')")"
    if [ "$n" = "1" ]; then
      pass "  $name: canonical sentence $((i + 1)) VERBATIM, exactly once"
    elif [ "$n" = "0" ]; then
      fail "  $name: MISSING (or reworded) canonical sentence $((i + 1)) — an instruction did not reach this body"
      ok=0
    else
      fail "  $name: canonical sentence $((i + 1)) appears ${n}x — a duplicate append"
      ok=0
    fi
  done
  # THE FRAMING, IN THE DELIVERED TEXT. Pinning it only at the source let a send-site substitution
  # ("an ORDER, not a report." -> "OPTIONAL CONTEXT, REPORTING IS ENOUGH.") ship green, keeping
  # every sentence while inverting what they are.
  if hasi "$body" "an order, not a report"; then
    pass "  $name: carries the framing ('an ORDER, not a report') in the DELIVERED text"
  else
    fail "  $name: lost or reworded the framing ('an ORDER, not a report') — the sentences are there but no longer an order"
    ok=0
  fi
  [ "$ok" = "1" ]
}
len_check(){ # len_check <state> <delivered>
  local name="$1" body="$2" want="${EXPECT_LEN[$1]}"
  if [ "${#body}" = "$want" ]; then
    pass "$name: delivered body is exactly ${want} bytes (nothing added, nothing removed)"
  else
    fail "$name: delivered body is ${#body} bytes, expected ${want} — text was ADDED to or REMOVED from this body; if the change is intended, update EXPECT_LEN[$name] in tests/heartbeat-fleet-advance/run.sh deliberately"
  fi
}
state(){ # state <name> <ask> <lanes> [mq] [obj]
  local name="$1"; shift
  local h="$TMP/$name"; sandbox "$h" "$@"
  local out; out="$(beat "$h" "$HB")"
  if [ -z "$out" ]; then
    fail "$name: produced NO message — the tick exited before sending (guard changed?)"
    return 1
  fi
  printf '%s' "$out"
}

echo ""
echo "1. the PLAIN pulse states — no lanes, one working lane, and a working+waiting-child fleet"
# Three states, not one: review measured mutants keyed on N_TOTAL>0, N_TOTAL>1 and N_WAIT>0 that
# dropped the order in the fleet's commonest states while a single-state driver stayed green.
for _s in quiet busy wait; do
  case "$_s" in
    quiet) _lanes=empty ;; busy) _lanes=busy ;; wait) _lanes=wait ;;
  esac
  body="$(state "$_s" 0 "$_lanes")" || continue
  if hasi "$body" "no alerts."; then
    pass "$_s: is the SHORT FORM (the body that rebuilds MSG)"
  else
    fail "$_s: did not take the short form — this state is not testing the pulse path"
  fi
  # The pulse states carry nothing after the order: it must be what the pane shows LAST.
  case "$body" in
    *"${ORDER[3]} "*) pass "$_s: ends with the order's closing sentence (nothing follows it)" ;;
    *)                 fail "$_s: does not end with the order's closing sentence — a clause now follows the order, or the order is gone" ;;
  esac
  order_check "$_s" "$body"
  len_check "$_s" "$body"
done

echo ""
echo "2. the CAPACITY state — a conditional clause present, the order immediately before it"
body="$(state cap 0 cap)" || body=""
if [ -n "$body" ]; then
  if hasi "$body" "capacity:"; then
    pass "cap: the CAPACITY clause really fired (the conditional path is exercised)"
  else
    fail "cap: no CAPACITY clause — this state would not prove the order survives a conditional"
  fi
  # "The order first, the detail it acts on second" is a claim in the script's own comment; it was
  # untested, and swapping the two appends stayed green.
  # TWO spaces between them, not one: the order literal ends with a space and the append adds its
  # own separator, so the delivered text reads "… WASTED BEAT.  ⛔ CAPACITY: …".
  if hasi "$body" "$(printf '%s' "${ORDER[3]}" | tr '[:upper:]' '[:lower:]')  ⛔ capacity:"; then
    pass "cap: the order is immediately followed by the CAPACITY clause (order first, detail second)"
  else
    fail "cap: the CAPACITY clause does not immediately follow the order — the append order changed"
  fi
  order_check cap "$body"
  len_check cap "$body"
fi

echo ""
echo "3. the ALERT-BODY states — a routed question, an alerting lane, a queue bottleneck, an objective at risk"
body="$(state question 1 empty)" || body=""
if [ -n "$body" ]; then
  if hasi "$body" "needing attention."; then
    pass "question: is the FULL body (built before the short-form overwrite)"
  else
    fail "question: did not take the full-body path — the alert body is unpinned"
  fi
  if hasi "$body" "$(printf '%s' "$_elab_expected" | tr '[:upper:]' '[:lower:]')"; then
    pass "question: carries the alert-only elaboration"
  else
    fail "question: lost its elaboration — the alert body is carrying the short variant"
  fi
  order_check question "$body"
  len_check question "$body"
fi
for _pair in "alert:0:alert:none:ok" "bottleneck:0:empty:bottleneck:ok" "objective:0:empty:none:risk"; do
  IFS=: read -r _name _ask _lanes _mq _obj <<< "$_pair"
  body="$(state "$_name" "$_ask" "$_lanes" "$_mq" "$_obj")" || continue
  order_check "$_name" "$body"
  len_check "$_name" "$body"
done

echo ""
echo "4. proportionality: the quiet body is the shorter one, and the order clause is bounded"
quiet_body="$(state q1 0 empty)" || quiet_body=""
full_body="$(state q2 1 empty)" || full_body=""
if [ -n "$quiet_body" ] && [ -n "$full_body" ]; then
  if [ "${#quiet_body}" -lt "${#full_body}" ]; then
    pass "the quiet beat is shorter than the alert beat (${#quiet_body} < ${#full_body} bytes)"
  else
    fail "the quiet beat (${#quiet_body}) is not shorter than the alert beat (${#full_body}) — bodies are swapped"
  fi
fi
_rend="$(text_of FLEETADV_SHORT)"
# Plain parameter expansion — never `eval`. The patterns are single-quoted so bash treats them as
# literal text, and the replacement is the sentence read from the shipped script.
_rend="${_rend//'${FA1}'/$(text_of FA1)}"
_rend="${_rend//'${FA2}'/$(text_of FA2)}"
_rend="${_rend//'${FA3}'/$(text_of FA3)}"
_rend="${_rend//'${FA4}'/$(text_of FA4)}"
# ⛔ A FIXED ceiling on the order's own wording (624 bytes shipped). Deliberately NOT derived from
# the text it bounds: a derived bound relaxes itself when the thing it bounds grows.
_order_ceiling=700
if [ "${#_rend}" -lt "$_order_ceiling" ]; then
  pass "the SHORT order wording is under the fixed ${_order_ceiling}-byte ceiling (${#_rend} bytes)"
else
  fail "the SHORT order wording is ${#_rend} bytes, over the fixed ${_order_ceiling}-byte ceiling — it is growing into the full text"
fi

echo ""
echo "5. SENSITIVITY: the same driver against a mutant of the shipped script must FAIL"
# The mutant empties the four SENTENCES and both composed bodies, so the only difference in the
# delivered beat is the order. If the clause still appears, this suite is reading something other
# than the shipped clause and would be permanently green.
MUT="$TMP/mutant.sh"
/usr/bin/python3 - "$HB" "$MUT" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
out = []
for ln in open(src, encoding="utf-8").read().splitlines(True):
    hit = ln.startswith(("FA1=", "FA2=", "FA3=", "FA4=", "FLEETADV=", "FLEETADV_SHORT="))
    out.append(ln.split("=")[0] + '=""\n' if hit else ln)
open(dst, "w", encoding="utf-8").writelines(out)
PY
mh="$TMP/mutant"
sandbox "$mh" 0 empty
_mout="$(beat "$mh" "$MUT")"
if [ -z "$_mout" ]; then
  fail "the MUTANT produced no message — the sensitivity check could not run, so nothing is pinned"
elif hasi "$_mout" "fleet advance"; then
  fail "the MUTANT still carried the clause — the assertions above are not reading the shipped text"
else
  pass "emptying the sentences removes the clause from the same driver (assertions are sensitive)"
fi
for _i in 0 1 2 3; do
  if [ "$(count_of "$_mout" "$(printf '%s' "${ORDER[$_i]}" | tr '[:upper:]' '[:lower:]')")" = "0" ]; then
    pass "  the mutant lost canonical sentence $((_i + 1)) — the assertion on it is live, not vacuous"
  else
    fail "  the mutant still carries canonical sentence $((_i + 1)) — that assertion cannot fail"
  fi
done

echo ""
# ⛔ A FLOOR ON THE ASSERTION COUNT, SET TO THE SHIPPED COUNT EXACTLY. A lower number leaves slack in
# which a single-check guard can be deleted while the suite still reports green (measured in review:
# a 30-of-36 floor absorbed three such deletions). At the exact count any removal is red. Adding
# assertions is safe; REMOVING one means lowering this number deliberately, which is the point.
MIN_CHECKS=89
if [ "$checks" -lt "$MIN_CHECKS" ]; then
  fail "only $checks assertions ran, below the shipped floor of $MIN_CHECKS — a check was removed"
fi
if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-fleet-advance suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-fleet-advance suite: $failures of $checks assertion(s) failed"
exit 1
