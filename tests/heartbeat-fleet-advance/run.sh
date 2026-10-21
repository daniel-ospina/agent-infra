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
#   Twelve review rounds produced the same finding in different clothes: an assertion that
#   pins a LOWER BOUND ("the four sentences are present") cannot fail on text that is ADDED,
#   and one that pins a SAMPLE of the state space ("the quiet beat with an empty fleet")
#   cannot fail on an edit keyed on a state it never visits. So this suite pins EXACTNESS and
#   EXACTNESS-PER-STATE, and it declares the threats it covers — a declared surface is a boundary a
#   reviewer can test against, while "we fixed what the last round found" is an open-ended chase.
#
#   ⛔ DECLARED THREAT SURFACE (each covered by a test below; residuals are named at the end):
#     T1  the order is ABSENT from a delivered beat (deleted, or dropped in one state);
#     T2  the order is GATED — composed for some inputs and not others (an `if` around an append,
#         around the send, or around a body literal);
#     T3  the order is REWORDED or SOFTENED in place, including an equal-length substitution in
#         prose no other assertion reads (hence goldens, not lengths);
#     T4  the order is REWRITTEN ON ITS WAY OUT (a read of $MSG that filters, slices or substitutes);
#     T5  a body is ADDED TO after the order (a clause appended behind the closing sentence);
#     T6  the egress changes: ANOTHER send (any spelling, any branch), a different payload, or a
#         third statement that delivers after the beat;
#     T7  the framing goes ("an ORDER, not a report") so the beat reads as a status report.
#
#   Covering them:
#     * the four order sentences are FIXED in this file (never read from the script under
#       test — an expectation taken from the artifact cannot fail on it), and the shipped
#       FA1..FA4 must EQUAL them;
#     * both composed bodies are pinned to their exact documented text, so nothing can be
#       added to, reordered in, or reworded in either one;
#     * the delivered beat is pinned BY GOLDEN (a byte-for-byte file) in SIXTEEN states covering
#       every branch that COMPOSES the message: no lanes / one working lane / working+waiting-child /
#       a 6-lane fleet (the ordinary size — nothing else visited 5-11, so a gate keyed on that band was
#       invisible) / a 12-lane fleet / a 26-lane fleet at the TOP of the range this script records /
#       idle capacity /
#       alert+capacity / dead panes / no live pi record / a routed question / an alerting lane / a
#       merge-queue bottleneck / an objective at risk / a WARM fleet with a verdict already reported
#       inside the hour (the only state that reaches N_KNOWN>=2 — every other state is a cold tick),
#       and a state where the PRIMARY send returns non-zero so the recovery egress executes.
#       Each must carry the four sentences exactly once. NOT covered, and said rather than implied:
#       gates that send NOTHING (kill file, no registry, PULSE_MIN, DRY, the liveness and idle
#       guards) and the TRIAGE_*/RL families, whose fixture inputs are permanently empty here.
#     * ordering is checked where the comment claims it: in the capacity state the order is
#       immediately followed by the CAPACITY clause, and in the plain pulse states the order
#       is the LAST thing in the beat;
#     * a coarse static lint counts statements that touch the order or MSG. It catches a NEW
#       statement (an added append, an `eval`, a `printf -v MSG`); it says nothing about text
#       added inside an existing literal — that is the goldens' job. The lint is labelled as a
#       lint on purpose: two rounds were spent on a count that claimed to prove more than a
#       count can.
#     * the ORDER IS NOT APPENDED, IT IS EMBEDDED IN THE TWO BODY LITERALS. Review measured a
#       two-line edit that wrapped each append in an `if` (block keywords on their own lines),
#       changed no count, tripped no visited state and dropped the order in the fleet's normal
#       state. There is no append OF THE ORDER left to wrap (the seven MSG appends that remain add
#       other clauses; `${FLEETADV}` rides the PRIORITY append and `${FLEETADV_SHORT}` the short-form
#       literal): to condition it now you must edit a body literal, strip it back out with a new
#       statement (an added line changes the executable-line count), or rewrite the message on its way
#       out — and THE EGRESS IS PINNED: the two `cmux send` statements (the message, and the recovery
#       `'\n'`) in their exact shipped forms and positions, no slicing or substitution of $MSG, the
#       block depth at the send and at the last MSG= statement each pinned to its shipped constant, the
#       block-keyword lines hashed, and the EXECUTED send count asserted per state.
#     * a mutant of the shipped script must LOSE the clause through the same driver, so a
#       driver that never reached the fragment cannot report a permanent green.
#
#   ⛔ EXECUTION, NOT SPELLING. A static count sees how a send is WRITTEN; the cmux stub reports every
#   invocation through an INHERITED FD (an unlinked fifo — no path to find, append-only so it can only
#   fail closed), and each state asserts how many sends the tick actually MADE (1, or 2 on `rcfail`).
#   Review defeated a substring count with `"$_cx" send` and with `cmux  send` inside a backgrounded
#   brace group, both green — those are now a red twice over (the token `send` appears on six
#   comment-stripped lines and exactly two of them spawn `cmux`; and the executed count is pinned).
#
#   ⛔ RESIDUALS, NAMED (not claimed as covered): (a) the tick's REACHABILITY of the send under an
#   input no state visits — a guard keyed on an unmodelled input can still silence the beat; (b) WHICH
#   PANE the beat is typed into (`ORCH_WS` / `ORCH_SURFACE` — the fixture's fake pane reports the
#   script's own values, so a destination change is self-consistent); (c) an edit that alters text
#   outside every clause the beats carry; (d) a background job that outlives the tick by more than the
#   recorder's grace window (the recorder reads the invocation log immediately after exit). Each is
#   outside what a fixture can prove; (a) is bounded by the sixteen visited states, not closed.
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

SUT="$HB"          # the script under test; §6 repoints it at a mutant
checks=0; failures=0
pass(){ checks=$((checks + 1)); echo "  ok   $1"; }
fail(){ checks=$((checks + 1)); failures=$((failures + 1)); echo "  FAIL $1"; }
# ⛔ A SUBSTRING TEST THAT IS NOT THE SIGPIPE IDIOM (#841/#864): a `printf … | grep -q` here
# would race under pipefail and can take the `else` branch — reporting PASS on a WITHHOLDING
# assertion, i.e. exactly backwards. Case globs have no upstream writer to race with.
# `hasi` lowercases the HAYSTACK only, so every needle passed to it must be lowercase.
# ⛔ AN EMPTY NEEDLE MATCHES EVERYTHING: `case "x" in *""*)` is true, so an undefined or empty
# expectation passes silently (measured: an unbound `_elab_expected` produced one unconditional "ok"
# and a green suite). Refuse it instead — under `set -u` an unbound variable makes the command
# substitution fail, and the empty result used to sail through.
hasi(){ [ -n "${2:-}" ] || return 1; case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# `count_of` — how many times a needle occurs. Not a quiet grep: `grep -o` writes to the pipe,
# so there is no SIGPIPE race under `pipefail`, and an exact count is what makes "the order
# appears twice" (a duplicate append inflating every beat) a red instead of a pass.
count_of(){ [ -n "${2:-}" ] || { echo 0; return 0; }
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | grep -o -F "$2" | wc -l | tr -d ' '; }

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
# Shipped: 7 appends of the form MSG="${MSG} …" (ROLE, MAP, PRIORITY, and the inline capacity /
# queue / objective / questions clauses), 10 MSG= occurrences, 11 executable lines mentioning MSG,
# 8 lines touching the order (6 definitions + the 2 body literals that embed it).
lint(){ # lint <label> <got> <want>
  if [ "$2" = "$3" ]; then
    pass "lint: $1 = $3 (an added statement would change it)"
  else
    fail "lint: $1 is now $2 (expected $3) — a statement was added or removed; if deliberate, update this number in §0 of tests/heartbeat-fleet-advance/run.sh and say why in the commit message"
  fi
}
lint 'MSG="${MSG} …" appends' "$_lint_appends" 7
lint 'MSG= occurrences (anywhere in a line)' "$_lint_assigns" 10
lint 'executable lines mentioning MSG' "$_lint_msg_lines" 11
lint 'executable lines touching the order' "$_lint_order_lines" 8
# ⛔ COMPOSITION, EXACTLY — AND THE EXPECTATIONS ARE FIXED HERE, NOT READ FROM THE SCRIPT.
# "The variant carries the four sentences" permits ADDITION, and "the body is N bytes" permits an equal
# REPLACEMENT: review measured a countermand of the same length as the alert-only elaboration, and a
# countermand inserted INSIDE the order paid for with 26 bytes deleted elsewhere, both green. So both
# composed literals are pinned to their FULL exact text — header, sentences, separators and the alert-
# only elaboration — and the elaboration is asserted ABSENT from the pulse bodies.
_elab_expected="Lanes must be running on real work, not described in a paragraph about load."
_EXPECT_SHORT='⛔ FLEET ADVANCE — an ORDER, not a report. ${FA1} ${FA2} ${FA3} ${FA4}${WL_ORDER} '
_EXPECT_FULL="⛔ FLEET ADVANCE — an ORDER, not a report. (1) \${FA1} (2) \${FA2} ${_elab_expected} (3) \${FA3} \${FA4}\${WL_ORDER} "
# ⛔ `${WL_ORDER}` IS IN BOTH EXPECTATIONS ON PURPOSE (owner, 2026-10-21). The overnight worklist is
# FILE-BACKED (`$STATE/OVERNIGHT-WORKLIST.md`) and appended to the ORDER's tail in BOTH body literals —
# the only shape that survives the short form's MSG rebuild. It is EMPTY on a box with no worklist, so
# it adds no bytes to any golden body; what this pin forbids is adding the list anywhere ELSE (an
# append after the short-form rebuild, a new statement, a slice) and calling that equivalent.
for _pair in "FLEETADV:$_EXPECT_FULL" "FLEETADV_SHORT:$_EXPECT_SHORT"; do
  _name="${_pair%%:*}"; _want="${_pair#*:}"
  if [ "$(text_of "$_name")" = "$_want" ]; then
    pass "$_name is EXACTLY its documented composition (no added clause, no reordering, no rephrase)"
  else
    fail "$_name differs from its documented composition — a variant may differ only by elaboration (got: $(text_of "$_name"))"
  fi
done
# ⛔ THE ORDER IS EMBEDDED, NOT APPENDED. Exactly two executable references to the composed bodies
# may exist outside their own definitions: the full-body literal and the short-form literal. A third
# reference is a statement that can gate or strip the order; a missing one means a body lost it.
_ref_full="$(printf '%s\n' "$_nc" | grep -cE '^MSG="\$\{MSG\} .*\$\{FLEETADV\}"$' || true)"
_ref_short="$(printf '%s\n' "$_nc" | grep -cE '^  MSG="\[HEARTBEAT .*\$\{FLEETADV_SHORT\}"$' || true)"
if [ "${_ref_full:-0}" = "1" ] && [ "${_ref_short:-0}" = "1" ]; then
  pass "the order is EMBEDDED in both body literals (full body ${_ref_full}, short-form body ${_ref_short}) — there is no append statement to make conditional"
else
  fail "the order is not embedded in the two body literals (full-body references=${_ref_full:-0}, short-form references=${_ref_short:-0}) — a body builds its message without the order, so the order would not ship in it"
  echo "❌ heartbeat-fleet-advance suite: the clause is not wired"; exit 1
fi
# ⛔ THE EGRESS IS PINNED. The message leaves this script through ONE statement, and a send-site
# rewrite (`${MSG:0:400}`, `${MSG/⛔ FLEET ADVANCE*/}`) needs no new line and changes no count — it
# was measured green twice before this check existed. So: the message send in its exact shipped form
# AND position, the recovery send in its exact shipped form, and no slicing/substitution of MSG
# anywhere in the file.
_egress="$(printf '%s\n' "$_nc" | grep -cE '^err=\$\(cmux send --workspace "\$ORCH_WS" --surface "\$ORCH_SURFACE" "\$MSG\\n" 2>&1\)$' || true)"
_slicing="$(printf '%s\n' "$_nc" | grep -cE '\$\{?MSG[:/%#]' || true)"
lint 'send statements in their exact shipped form' "$_egress" 1
# ⛔ THE SECOND SEND IS AN EGRESS TOO. There are TWO `cmux send` calls: the message, and the recovery
# `'\n'` that releases a parked composer when the first one returned non-zero. The claim "exactly one
# send" was false, and the recovery send's payload was constrained by nothing — review appended an
# order-cancelling sentence to it and shipped green (it only runs when rc≠0, so the fixture has to be
# able to fail a send for that path to be exercised at all).
_egress2="$(printf '%s\n' "$_nc" | grep -cE "^  e2=\\\$\\(cmux send --workspace \"\\\$ORCH_WS\" --surface \"\\\$ORCH_SURFACE\" '\\\\n' 2>&1\\)$" || true)"
lint 'recovery send statements in their exact shipped form' "$_egress2" 1
# ⛔ THERE IS A THIRD WAY TO SEND: A NEW STATEMENT. The two lines above pin the two *known* sends by
# text; they say nothing about a THIRD one added anywhere (review appended a backgrounded
# `( sleep 1; cmux send … "CORRECTION: …" ) &` before the final exit and the suite stayed green — the
# body and the receipt were both untouched). So the TOKEN `send` is confined to six known lines, of
# which exactly two spawn cmux, and one spelling of backgrounding is pinned at 0.
# ⛔ THESE ARE LINTS WITH KNOWN BLIND SPOTS, NOT PROPERTIES. Review defeated an earlier version with
# `"$_cx" send` and with `cmux  send` (two spaces, inside a brace group with `&`) and defeated THIS
# version with `_sb=se; _sb="${_sb}nd"; cmux "$_sb" …` — a send that writes no `send` token at all. The
# property is the RUNTIME count below (every executed invocation is recorded and counted per state);
# the token lint exists to catch the common spellings early and to make the known ones explicit.
_send_word="$(printf '%s\n' "$_nc" | grep -cE '(^|[^[:alnum:]_])send([^[:alnum:]_]|$)' | tr -d ' ')"
lint 'lines containing the token send (comment-stripped)' "$_send_word" 6
_send_cmux="$(printf '%s\n' "$_nc" | grep -E '(^|[^[:alnum:]_])send([^[:alnum:]_]|$)' \
  | grep -cE '(^|[^[:alnum:]_])cmux[[:space:]]+send' | tr -d ' ')"
lint 'of those, lines that actually spawn cmux' "$_send_cmux" 2
_bg="$(printf '%s\n' "$_nc" | grep -cE '\)[[:space:]]*&[[:space:]]*$' | tr -d ' ')"
lint 'lines ENDING in & (one spelling of backgrounding; a `) & # comment` tail is NOT caught — residual (d))' "$_bg" 0
# ⛔ AND THE PRIMARY SEND'S *POSITION*, NOT JUST ITS TEXT. Wrapping the send in
# `if [ "$N_TOTAL" -lt 13 ]; then … fi` changes no count, leaves every golden intact, and silences the
# beat on every fleet of 13+ lanes — measured green. The shipped shape is: a comment line, the send,
# `rc=$?`, a comment. Pinning the two neighbours makes any inserted control line a red.
_send_ln="$(printf '%s\n' "$_nc" | grep -nE '^err=\$\(cmux send --workspace' | head -1 | cut -d: -f1)"
if [ -n "${_send_ln:-}" ]; then
  # Read the NEIGHBOURS from the raw file: the line above the send is a COMMENT, and the comment-strip
  # used for the counts blanks it. Line numbers are the same in both because the strip only blanks.
  _case_prev="$(sed -n "$((_send_ln - 1))p" "$HB")"
  _case_next="$(sed -n "$((_send_ln + 1))p" "$HB")"
else
  _case_prev=""; _case_next=""
fi
# ⛔ NEIGHBOURS ARE A ±1-LINE SAMPLE; THE *SCOPE* IS THE PROPERTY. Pinning the line above and the line
# below is defeated by moving an `if` one line higher (measured green: a balanced
# `if [ "$N_TOTAL" -le 26 ]; then … fi` wrapped around the whole send+rc block, beating the ±1 pins and
# every golden at once). So the block DEPTH at the last MSG= statement and at the send are each pinned
# to a SHIPPED CONSTANT, and the block-keyword LINES are hashed so a compensated rewrite cannot pay for
# a wrapper. (The heuristic ignores comments, blanks and single-line `if …; fi`.)
_depth_at() {
  # Index by RAW line number (NR) over the raw file: the depth counter skips comments and blanks, so
  # it must NOT double as the line counter, or the number the grep produced never matches.
  awk -v want="$1" '
    { line=$0; sub(/^[ \t]+/, "", line)
      if (line ~ /^#/ || line == "") next
      if (line ~ /^(if|while|until|for|case)([ \t]|$)/ && line ~ /(fi|done|esac)[ \t]*$/) { if (NR==want) { print d; exit } next }
      if (line ~ /^(if|while|until|for|case)([ \t]|$)/) d++
      else if (line ~ /^(fi|done|esac)([ \t]|;|$)/) d--
      if (NR==want) { print d; exit }
    }' "$HB"
}
# ⛔ INDENTATION-AGNOSTIC ON PURPOSE: the LAST composition statement is an indented `MSG="$MSG …"`
# inside a guard (`script:1037`), and an earlier version matched only column-0 `MSG=` — so the pin's
# reference was `script:1002` and the claim "same depth as the last composition" was false of the
# shipped file itself. Both depths are now compared against their own SHIPPED CONSTANT, not against
# each other: a reference taken from the artifact cannot fail on it (a lesson already paid for twice).
_last_msg_ln="$(grep -nE '^[[:space:]]*MSG[+]?=' "$HB" | tail -1 | cut -d: -f1)"
_depth_msg="$(_depth_at "${_last_msg_ln:-1}")"
_depth_send="$(_depth_at "${_send_ln:-1}")"
lint 'block depth at the last MSG= statement' "${_depth_msg:-?}" 25
lint 'block depth at the send' "${_depth_send:-?}" 24
# ⛔ AND A WRAPPER KEYED ON A PREDICATE THAT HOLDS IN *EVERY VISITED STATE* IS INVISIBLE TO SAMPLING.
# Review measured `if [ "$N_TOTAL" -le 4 ] || [ "$N_TOTAL" -ge 12 ]; then` wrapped around the send —
# and then defeated two NET counts by paying for the wrapper with a compensating two-line rewrite. So
# the keyword LINES are hashed (`cksum`, POSIX — `md5sum` is not on macOS): any insertion, deletion,
# reorder or rewrite among them changes the digest. A rewritten line with the keywords removed entirely
# is caught by the executable-line count below instead.
_blk_sig="$(grep -E '^[[:space:]]*(if|while|until|for|case|fi|done|esac)([[:space:]]|;|$)' "$HB" \
  | cksum | cut -d' ' -f1-2 | tr -d ' ')"
# ⛔ RE-PINNED 2026-10-19 (#1867), DELIBERATELY, WITH THE DIFF CHECKED: the digest moved from
# 21188013054935 to 40775937054958 because the `WORKING` counter inside this script's Python heredoc
# went from `if v in ("WORKING",): act+=1` to `if v in ("WORKING", "UNATTRIBUTED-WORKING"): act+=1` —
# a REWRITE of one matched line, not an added block. Verified when re-pinning: the matched line COUNT
# is 148 both before and after, and the diff of the matched lines is exactly that one line.
# THE PIN IS COARSE BY DESIGN, and this is its blind spot worth naming: the pattern matches `if`
# inside heredoc PYTHON as well as shell, so any heredoc edit that rewrites such a line re-pins here.
# That direction is the SAFE one — the digest cannot go stale silently — so the lint is UPDATED
# rather than narrowed (narrowing it to shell-only would stop hashing heredoc control lines, a real
# place to hide a gate). Untouched by this change: the executable-line pin below, which did NOT move.
# ⛔ RE-PINNED 2026-10-21, DELIBERATELY, WITH THE DIFF CHECKED: 40775937054958 -> 5896617145261 and
# 494 -> 518 executable lines, because the ORDER now carries the FILE-BACKED OVERNIGHT WORKLIST
# (`$STATE/OVERNIGHT-WORKLIST.md`): one `while`/`case`/`if` read of that file, before the order
# literals, so both body forms carry the list. A LATE GATE ADDING A STATEMENT OR A BLOCK MOVES THESE
# NUMBERS, WHICH IS EXACTLY WHAT THEY ARE FOR — the diff that moved them is the worklist reader and
# the two `${WL_ORDER}` interpolations, nothing else (verified: no new `MSG=` line, no new send, no
# change to the guard or the order's sentences).
lint 'block-keyword line signature (cksum of the opener/closer lines)' "$_blk_sig" "5896617145261"
# ⛔ AND A NEW STATEMENT IS NOT FREE. The pins above count tokens and structures; a gate written as one
# extra line with no block keyword and no `send` token — `[ "$N_TOTAL" -le 4 ] || exit 0` — was measured
# green, silencing the beat on every 5-11 lane fleet. So the number of executable lines is pinned.
_exec_lines="$(printf '%s\n' "$_nc" | grep -c '[^[:space:]]' | tr -d ' ')"
lint 'executable lines (comment-stripped, non-blank)' "$_exec_lines" 518
case "$_case_prev" in
  '#'*) pass "the primary send has a comment immediately above it (no control line was inserted)" ;;
  *)    fail "the line above the primary send is not a comment ('${_case_prev:0:60}') — a conditional was wrapped around the send, which silences the beat for whichever states fail it" ;;
esac
if [ "$_case_next" = 'rc=$?' ]; then
  pass "the primary send is followed by rc=\$? (its result is captured unconditionally)"
else
  fail "the primary send is not followed by rc=\$? ('${_case_next:0:60}') — its result is now inside a conditional"
fi
lint 'slicing/substitution of MSG anywhere (${MSG…}, $MSG…) ' "$_slicing" 0
# ⛔ EVERY OTHER USE OF MSG IS ALLOWED TO BE ONE OF TWO SHAPES. A `sed`/`printf` rewrite that pipes `$MSG`
# through a filter needs no new line, changes no count, and was measured green once (the headline
# became "DEFER ADVANCE" on every alert beat). So: drop the appends' own `${MSG}` prefix and the pinned
# send from the source, and NOTHING may still mention MSG.
_msg_other="$(printf '%s\n' "$_nc" \
  | grep -E '\$(\{)?MSG' \
  | grep -vE 'MSG(\+)?="\$(\{MSG\}|MSG) ' \
  | grep -vE '^err=\$\(cmux send --workspace "\$ORCH_WS" --surface "\$ORCH_SURFACE" "\$MSG\\n" 2>&1\)$' \
  | wc -l | tr -d ' ')"
if [ "${_msg_other:-0}" = "0" ]; then
  pass "no line reads MSG except the body appends and the pinned send (${_msg_other} other)"
else
  fail "${_msg_other} line(s) read \$MSG outside the body appends and the pinned send — the message must leave as the literals themselves; a rewrite on the way out (even a read for a log line) needs a deliberate change here first"
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
  # `read-screen` decides DEAD vs OCCUPIED: a bare-shell prompt makes _shell_visible true, an idle-pi
  # line makes it false. Only the `dead` state gets the prompt.
  local _screen="  idle at the prompt"
  [ "$lanes" = "dead" ] && _screen='user@box ~ % ' 
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
    # a production-size fleet (this file records fleets up to 26 lanes): the length pin is the ONLY thing
    # that can see fleet size, so a fleet-size-keyed edit is invisible without a big-fleet state
    prod)  _rows='[{"lane":"l1","ws":"w1","verdict":"WORKING"},{"lane":"l2","ws":"w2","verdict":"WAITING-CHILD","child":{"age":1200}},{"lane":"l3","ws":"w3","verdict":"WORKING"},{"lane":"l4","ws":"w4","verdict":"WAITING-CHILD","child":{"age":900}},{"lane":"l5","ws":"w5","verdict":"WORKING"},{"lane":"l6","ws":"w6","verdict":"WAITING-CHILD","child":{"age":600}},{"lane":"l7","ws":"w7","verdict":"WORKING"},{"lane":"l8","ws":"w8","verdict":"WAITING-CHILD","child":{"age":400}},{"lane":"l9","ws":"w9","verdict":"WORKING"},{"lane":"l10","ws":"w10","verdict":"WAITING-CHILD","child":{"age":300}},{"lane":"l11","ws":"w11","verdict":"WORKING"},{"lane":"l12","ws":"w12","verdict":"WAITING-CHILD","child":{"age":200}}]' ;;
    # an ALERT plus free capacity: the full body WITH the capacity clause. Review measured that no
    # state had N_CAP>0 on the full-body path, so wrapping the full body in a capacity test dropped
    # the order with this suite green.
    alertcap) _rows='[{"lane":"2b","ws":"w2","verdict":"EMPTY"},{"lane":"2a","ws":"'"$ws"'","verdict":"DONE-IDLE","stale_s":3600}]' ;;
    # the TOP of the fleet range this file records (up to 26 lanes). A matrix whose largest
    # fleet is 12 lanes cannot see a threshold of 13: review measured `if [ "$N_TOTAL" -lt 13 ]; then`
    # wrapped around the SEND, green, silencing every beat on a 13+ lane fleet.
    huge)  _rows='[{"lane":"l1","ws":"w1","verdict":"WORKING"},{"lane":"l2","ws":"w2","verdict":"WAITING-CHILD","child":{"age":1200}},{"lane":"l3","ws":"w3","verdict":"WORKING"},{"lane":"l4","ws":"w4","verdict":"WAITING-CHILD","child":{"age":900}},{"lane":"l5","ws":"w5","verdict":"WORKING"},{"lane":"l6","ws":"w6","verdict":"WAITING-CHILD","child":{"age":600}},{"lane":"l7","ws":"w7","verdict":"WORKING"},{"lane":"l8","ws":"w8","verdict":"WAITING-CHILD","child":{"age":400}},{"lane":"l9","ws":"w9","verdict":"WORKING"},{"lane":"l10","ws":"w10","verdict":"WAITING-CHILD","child":{"age":300}},{"lane":"l11","ws":"w11","verdict":"WORKING"},{"lane":"l12","ws":"w12","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l13","ws":"w13","verdict":"WORKING"},{"lane":"l14","ws":"w14","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l15","ws":"w15","verdict":"WORKING"},{"lane":"l16","ws":"w16","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l17","ws":"w17","verdict":"WORKING"},{"lane":"l18","ws":"w18","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l19","ws":"w19","verdict":"WORKING"},{"lane":"l20","ws":"w20","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l21","ws":"w21","verdict":"WORKING"},{"lane":"l22","ws":"w22","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l23","ws":"w23","verdict":"WORKING"},{"lane":"l24","ws":"w24","verdict":"WAITING-CHILD","child":{"age":200}},{"lane":"l25","ws":"w25","verdict":"WORKING"},{"lane":"l26","ws":"w26","verdict":"WAITING-CHILD","child":{"age":200}}]' ;;
    # an idle lane whose pane is a BARE SHELL: the DEAD LANES clause fires (the sandbox sets
    # CMUX_SCREEN to a shell prompt). Review measured this clause delivering text no pin had seen.
    # ⛔ A WARM TICK — the one input class this matrix has never had. Every other state is a COLD tick
    # (fresh $HOME, no lane-known.json), so N_KNOWN is 0 everywhere and a guard keyed on it
    # (`[ "${N_KNOWN:-0}" -ge 2 ] && exit 0`) silences the beat on every real fleet tick with this suite
    # green (measured 131/131 by review). Here two verdicts are already "known" (reported within the
    # re-alert window) and a third is fresh, so N_KNOWN=2 and the alert clause fires on the full body.
    # 4 lanes: l2 alerts (fresh EMPTY), l3 and l4 are inside their re-alert window (so they land in the
    # KNOWN bucket, N_KNOWN=2), l1 is an ordinary working lane.
    warm)  _rows='[{"lane":"l1","ws":"w1","verdict":"WORKING"},{"lane":"l2","ws":"w2","verdict":"EMPTY"},{"lane":"l3","ws":"w3","verdict":"EMPTY"},{"lane":"l4","ws":"w4","verdict":"DONE-IDLE","stale_s":3600}]' ;;
    # ⛔ THE ORDINARY FLEET SIZE. The matrix visited 0/1/2/4/12/26 lanes — nothing in 5-11 — so a gate
    # keyed on `[ "$N_TOTAL" -le 4 ] || [ "$N_TOTAL" -ge 12 ]` held in EVERY visited state and silenced
    # the beat on the fleet this tick actually runs (measured green, and the shipped script delivers in
    # a 6-lane fixture while the mutant does not). This state is that band.
    mid)   _rows='[{"lane":"l1","ws":"w1","verdict":"WORKING"},{"lane":"l2","ws":"w2","verdict":"WAITING-CHILD","child":{"age":1200}},{"lane":"l3","ws":"w3","verdict":"WORKING"},{"lane":"l4","ws":"w4","verdict":"WAITING-CHILD","child":{"age":600}},{"lane":"l5","ws":"w5","verdict":"WORKING"},{"lane":"l6","ws":"w6","verdict":"WAITING-CHILD","child":{"age":200}}]' ;;
    dead)  _rows='[{"lane":"2a","ws":"deadws","verdict":"DONE-IDLE","stale_s":3600}]' ;;
    # an idle lane with NO live pi record whose pane is unreadable: the "NO LIVE pi RECORD" clause
    # fires. Review measured this branch delivering text no pin had ever seen.
    nolive) _rows='[{"lane":"2a","ws":"gone","verdict":"DONE-IDLE","stale_s":3600}]' ;;
    # EMPTY/UNBOUND are in NURT but not WEAK, so no screen is attempted and the alert fires
    alert) _rows='[{"lane":"2b","ws":"w2","verdict":"EMPTY"}]' ;;
    *)     _rows='[]' ;;
  esac
  printf '#!/usr/bin/env python3\nimport json,sys\njson.dump(%s, sys.stdout)\n' \
    "$_rows" > "$h/.pi/agent/scripts/lane-status.py"
  # The WARM state's prior verdicts: two already reported inside the hour, so they land in the "known"
  # bucket rather than the alert one. `last_alert` is a far-future epoch so the entry never expires.
  [ "$lanes" = "warm" ] && printf '{"l3|EMPTY":{"last_alert":9999999999,"lane":"l3","verdict":"EMPTY"},"l4|DONE-IDLE":{"last_alert":9999999999,"lane":"l4","verdict":"DONE-IDLE"}}' \
    > "$h/.pi/agent/state/lane-known.json"
  # ⛔ THE SCREEN IS STUBBED TOO. `screened_stalled` shells out to lane-confirm.py by ABSOLUTE path,
  # which escapes this sandbox: on a box where that file exists the suite would call the live Jev
  # screen (real cost, ~30s) and its verdict would move the delivered body. The tick reads the path
  # from $LANE_CONFIRM so this stub is the one it uses; it answers "not stalled" (rc=1).
  printf '#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n' > "$h/.pi/agent/state/lane-confirm.py"
  export LANE_CONFIRM="$h/.pi/agent/state/lane-confirm.py"
  chmod +x "$h/.pi/agent/scripts"/*.py
  # `cmux` — the orchestrator pane must report a live pi (else the liveness guard withholds the
  # send), the pane must not look mid-turn (else the idle guard withholds it), and `send` is
  # recorded verbatim into the session file the tick then greps to verify its own delivery.
  # ⛔ THE MATCH IS ON THE FIRST TWO WORDS AND EVERYTHING ELSE IS LOGGED. Matching only `$1`
  # meant `cmux sessions kill …` was modelled as a read and the beat still went out green.
  # ⛔ THE RECORDER IS AN INHERITED FD, NOT A FILE PATH. It was a plain file in $TMP with its path
  # EXPORTED (and baked into the stub) — review measured a third send that copied the ledger, sent, and
  # restored the copy, so the count read 1 while a countermand had been typed into the pane in every
  # state. A path the system under test can find is a path it can restore; an fd on an UNLINKED fifo is
  # append-only and undiscoverable. Writing extra lines only INFLATES the count, which fails closed.
  exec 9>&- 2>/dev/null || true
  _sends_fifo="$TMP/sends.${h##*/}.fifo"
  rm -f "$_sends_fifo"; mkfifo "$_sends_fifo"
  exec 9<>"$_sends_fifo"
  rm -f "$_sends_fifo"
  cat > "$h/bin/cmux" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "sessions list") echo "workspace=$ws pid_exists=yes label=orchestrator" ;;
  "read-screen --workspace") echo "$_screen" ;;
  "send "*) _last=""; for _a in "\$@"; do _last="\$_a"; done
        printf 'send\n' >&9
        printf '%s' "\$_last" >> "\$HOME/.pi/agent/sessions/s1/hb-11111111-1111-1111-1111-111111111111.jsonl"
        # A FAIL-ABLE SEND. The rc!=0 path is ROUTINE in production (this script's own record: every
        # heartbeat in an 80-minute window logged an rc=1 send error and the text ARRIVED anyway),
        # yet no state could enter it, so anything added inside that branch was unexercised. With the
        # marker present the first send returns 1 but still delivers -- which is the measured
        # production behaviour, and it lets the tick's own delivery poll succeed.
        if [ -f "\$HOME/fail-first-send" ]; then rm -f "\$HOME/fail-first-send"; exit 1; fi
        ;;
  "surface resume") echo "--session' '11111111-1111-1111-1111-111111111111'" ;;
  *) printf '%s\n' "\$*" >> "\$HOME/.pi/agent/stub-unhandled.log" ;;
esac
exit 0
EOF
  chmod +x "$h/bin/cmux"
}
# ⛔ A BASH WATCHDOG, NOT `timeout`: macOS ships neither `timeout` nor `gtimeout` (this repo has
# recorded that more than once, e.g. scripts/orchestrator-harness/selftest.sh), and the owner develops
# on a Mac — with a bare `timeout` every beat would return nothing there and the suite would report
# "a check was removed", which is the opposite of the truth.
run_bounded(){ # run_bounded <secs> <cmd…>
  local secs="$1"; shift
  "$@" & local pid=$!
  # ⛔ POLLED IN THE PARENT, so there is no watchdog subshell and no orphaned `sleep`: killing a
  # wrapper subshell leaves its `sleep` running for the full deadline (measured: 16 `sleep 120`
  # processes alive after a run). Fractional sleep keeps the added latency at ~0.1s per beat.
  local tenths=0 max=$((secs * 10))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$tenths" -ge "$max" ]; then
      kill -9 "$pid" 2>/dev/null
      break
    fi
    sleep 0.1 2>/dev/null || sleep 1
    tenths=$((tenths + 1))
  done
  wait "$pid" 2>/dev/null
}
# ⛔ `beat` WRITES THE MESSAGE TO A FILE AND PRINTS NOTHING. It used to be called inside `$( )`, which
# put it in a subshell: its `fail` counts were lost and its diagnostic was captured INTO the body it
# was describing (measured: eight "produced NO message" failures printed nowhere, and the operator was
# told a check had been removed instead of "the tick sent nothing").
BEAT_MSG=""
beat(){ # beat <home> <script>; sets BEAT_MSG
  local h="$1" script="$2"
  BEAT_MSG=""
  run_bounded 120 env HOME="$h" PATH="$h/bin:$PATH" bash "$script" >"$h/tick.log" 2>&1
  # A cmux sub-command this fixture does not model means the tick depended on something nobody
  # stubbed: its answer is empty, which can read as a healthy empty fleet. Fail loudly, not green.
  if [ -s "$h/.pi/agent/stub-unhandled.log" ]; then
    fail "the tick called cmux sub-commands the fixture does not model: $(tr '\n' ';' < "$h/.pi/agent/stub-unhandled.log") — stub them before trusting this run"
  fi
  # ⛔ HOW MANY TIMES DID THE TICK ACTUALLY SEND? A static pin sees spellings; this sees EXECUTIONS.
  # Review measured a third egress hidden as `"$_cx" send` and as `cmux  send` inside a brace group —
  # both green against a substring count. The stub records every invocation, so a state's expected
  # count is a property of what ran, not of how it was written.
  local _want_sends="${EXPECT_SENDS:-1}"
  # Drain the channel to a SENTINEL the harness writes ITSELF, so no timeout is needed to know when to
  # stop reading (a fractional `read -t` is not available on the macOS bash 3.2 this suite supports).
  # Anything the SUT wrote before the sentinel is counted; a sentinel written early by the SUT lowers
  # the count, which fails; forged lines raise it, which also fails.
  _got_sends=0
  printf 'HARNESS-END\n' >&9
  while IFS= read -r -t 5 -u 9 _sl; do
    [ "$_sl" = "HARNESS-END" ] && break
    [ "$_sl" = "send" ] && _got_sends=$((_got_sends + 1))
  done
  if [ "${_got_sends:-0}" = "$_want_sends" ]; then
    pass "${h##*/}: the tick made exactly ${_want_sends} cmux send invocation(s)"
  else
    fail "${h##*/}: the tick made ${_got_sends} cmux send invocation(s), expected ${_want_sends} — another egress executed on this state (a countermand delivered after the beat defeats everything the body pins say)"
  fi
  # ⛔ THE TICK MUST HAVE VERIFIED ITS OWN SEND. When the recorded send does not verify, the tick
  # polls 20x5s; measured, one drifted stub detail turned this suite into 18 minutes of BOTH CI lanes
  # and still passed. `delivered=yes` is the tick's own receipt.
  # The tick's receipt lives in its own log ($STATE/orchestrator-heartbeat.log, i.e. under the sandbox
  # $HOME), not on stdout.
  if ! grep -qs 'delivered=yes' "$h/.pi/agent/state/orchestrator-heartbeat.log" 2>/dev/null; then
    fail "the tick never verified its delivery (no 'delivered=yes' in its log) — a stub drifted; the beat below may be recorded but was not confirmed"
  fi
  BEAT_MSG="$(cat "$h/.pi/agent/sessions/s1/hb-11111111-1111-1111-1111-111111111111.jsonl" 2>/dev/null)"
  # The tick sends `"$MSG\n"`, and the stub records argv verbatim, so the recording ends with the
  # two literal characters `\` and `n`. Strip them: BEAT_MSG must be the message, not its escape.
  # (A quoted `'\n'` glob inside `case` matches those two characters literally; `${x%\n}` would not,
  # because an unquoted `\` escapes the `n` and the pattern degenerates to "ends with n".)
  case "$BEAT_MSG" in *'\n') BEAT_MSG="${BEAT_MSG%??}" ;; esac
  # The timestamp is the only part of a beat that legitimately changes between runs. Normalise
  # EXACTLY `[HEARTBEAT HH:MM:SS]` — 20 bytes, digits and colons in place — and nothing else.
  # ⛔ NOT "everything up to the first `]`": review injected a countermand INSIDE the bracket and the
  # golden never saw it (measured green), because a loose normalisation eats whatever it finds there.
  case "$BEAT_MSG" in
    '[HEARTBEAT '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]']'*)
      BEAT_MSG="[HEARTBEAT <TS>]${BEAT_MSG:20}" ;;
  esac
  case "$BEAT_MSG" in
    '[HEARTBEAT <TS>]'*) : ;;
    *) fail "the beat does not start with a well-formed [HEARTBEAT HH:MM:SS] header — the golden cannot be normalised, and this is NOT a timestamp problem: the header itself changed" ;;
  esac
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
# ⛔ A GOLDEN BODY PER STATE, NOT A LENGTH. A length is a TOTAL: any equal-length substitution inside
# a clause nothing else asserts — review measured the CAPACITY clause rewritten from "hand each the
# next unheld item" to "do not hand any of them work" in the same 99 bytes — passes a length pin, and
# that is the #1991 failure ("a beat that reports state and dispatches nothing") reintroduced in the
# one clause that says how to USE the capacity. Presence and count pins cannot see it either, because
# the substitution is in prose they never look at. So each state's delivered body is compared byte for
# byte against `golden/<state>.txt`.
#
# ⛔ TO CHANGE A GOLDEN, YOU CHANGE IT DELIBERATELY: `UPDATE_GOLDEN=1 bash tests/…` rewrites the files,
# and the diff then shows every changed byte of every beat in the PR. Regenerating is not a fix for a
# red suite — it IS the change, in public. Each golden is also asserted to contain the order and the
# framing, so a golden cannot be regenerated from a script that lost them.
GOLDEN_DIR="$HERE/golden"
golden_check(){ # golden_check <state> <delivered>
  local name="$1"; local body="$2"
  local want; want="$GOLDEN_DIR/$name.txt"
  local got; got="$TMP/got.$name"
  printf '%s' "$body" > "$got"
  if [ "${UPDATE_GOLDEN:-0}" = "1" ]; then
    printf '%s' "$body" > "$want"
    pass "$name: golden REGENERATED (${#body} bytes) — review it in the diff before committing"
    return
  fi
  if [ ! -f "$want" ]; then
    fail "$name: no golden at tests/heartbeat-fleet-advance/golden/$name.txt — run UPDATE_GOLDEN=1 to create it, then review it"
    return
  fi
  # A golden regenerated from a script that lost the order would otherwise lock that loss in.
  if ! hasi "$(cat "$want")" "an order, not a report" \
     || [ "$(count_of "$(cat "$want")" "$(printf '%s' "${ORDER[3]}" | tr '[:upper:]' '[:lower:]')")" != "1" ]; then
    fail "$name: golden/$name.txt does not carry the order exactly once — a golden may not be regenerated from a beat that lost it"
    return
  fi
  # A state that claims to exercise N_KNOWN must actually reach it: the tick logs what it classified,
  # and review measured a guard on N_KNOWN>=2 that everything else here reproduced green.
  if [ "$name" = "warm" ]; then
    if grep -qs 'VERDICTS known=2:' "${STATE_HOME:-/nonexistent}/.pi/agent/state/orchestrator-heartbeat.log"; then
      pass "warm: the tick classified N_KNOWN=2 (the warm path really was reached)"
    else
      fail "warm: the tick did NOT classify N_KNOWN=2 — this state no longer exercises the warm path, so a guard keyed on N_KNOWN is invisible again"
    fi
  fi
  if cmp -s "$want" "$got"; then
    pass "$name: delivered body matches its golden byte for byte (${#body} bytes)"
  else
    # ⛔ Do NOT scrape the offset out of `cmp`'s output: its message embeds BOTH file paths, and the
    # temp path this suite uses carries a pid, so the "offset" could be a number out of the directory
    # name. `cmp -l` prints "byte-octet1 octet2" per difference — take its first field.
    local off
    off="$(cmp -l "$want" "$got" 2>/dev/null | head -1 | awk '{print $1}')"
    fail "$name: delivered body DIFFERS from golden/$name.txt at byte ${off:-?} — expected '$(dd if="$want" bs=1 skip=$((${off:-1}-1)) count=60 2>/dev/null | tr -d '\n')' got '$(dd if="$got" bs=1 skip=$((${off:-1}-1)) count=60 2>/dev/null | tr -d '\n')' (if the change is intended, regenerate with UPDATE_GOLDEN=1 and review the diff)"
  fi
}
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
# `state` fills BODY and returns 0/1 — no command substitution, so `fail` inside it counts in the
# parent shell and its message reaches the operator.
BODY=""
state(){ # state <name> <ask> <lanes> [mq] [obj]
  local name="$1"; shift
  local h="$TMP/$name"; sandbox "$h" "$@"
  # `rcfail` is the only state where the PRIMARY send returns non-zero, so the tick's recovery branch
  # (`e2=$(cmux send … '\n')`) is actually entered and its own egress is exercised.
  # ⛔ THE EXPECTED COUNT IS A HARNESS VARIABLE, NOT A FILE IN THE SANDBOX HOME. It used to be read
  # from `$HOME/expect-sends` — the SUT's OWN home: review measured a mutant that added a third send
  # and wrote `2` there, so the assertion compared the tick's record with the tick's own claim and went
  # green. Nothing the system under test can write may set its own expectation.
  EXPECT_SENDS=1
  [ "$name" = "rcfail" ] && { : > "$h/fail-first-send"; EXPECT_SENDS=2; }
  beat "$h" "$SUT"
  BODY="$BEAT_MSG"
  # The sandbox HOME of the state being checked: `golden_check` reads the tick's OWN log from it
  # (e.g. what it classified), so a state cannot silently stop exercising the path it was added for.
  STATE_HOME="$h"
  if [ -z "$BODY" ]; then
    fail "$name: produced NO message — the tick exited before sending (guard changed, or a stub drifted)"
    return 1
  fi
  return 0
}

echo ""
echo "1. the PLAIN pulse states — no lanes, one working lane, working+waiting-child, and a 12-lane fleet"
# Five states, not one: review measured mutants keyed on N_TOTAL>0, N_TOTAL>1, N_TOTAL>=3 and N_WAIT>0
# that dropped the order in the fleet's commonest states while a single-state driver stayed green, and
# a `if [ "$N_TOTAL" -lt 13 ]` around the SEND that silenced every beat on a 13+ lane fleet (this
# file records fleets up to 26 lanes) with the matrix largest fleet at 12.
# `warm` is NOT in this loop: it takes the FULL body (an alert plus two known verdicts), so it is
# driven below with the other alert states.
for _s in quiet busy wait mid prod huge; do
  case "$_s" in
    quiet) _lanes=empty ;; busy) _lanes=busy ;; wait) _lanes=wait ;; mid) _lanes=mid ;; prod) _lanes=prod ;; huge) _lanes=huge ;;
  esac
  state "$_s" 0 "$_lanes" || continue
  body="$BODY"
  if hasi "$body" "no alerts."; then
    pass "$_s: is the SHORT FORM (the body that rebuilds MSG)"
  else
    fail "$_s: did not take the short form — this state is not testing the pulse path"
  fi
  if hasi "$body" "$(printf '%s' "$_elab_expected" | tr '[:upper:]' '[:lower:]')"; then
    fail "$_s: carries the alert-only elaboration — the SHORT wording is not what shipped"
  else
    pass "$_s: omits the alert-only elaboration (the SHORT wording is what shipped)"
  fi
  # The pulse states carry nothing after the order: it must be what the pane shows LAST. An exact
  # TAIL comparison, not a substring — `*"${ORDER[3]} "*` matches anywhere and a clause appended after
  # the order stayed green (measured, with the length compensated out of the short literal).
  _want="${ORDER[3]} "
  if [ "${body: -${#_want}}" = "$_want" ]; then
    pass "$_s: ENDS with the order's closing sentence (nothing follows it)"
  else
    fail "$_s: does not END with the order's closing sentence — a clause now follows the order, or the order is gone (tail: '${body: -60}')"
  fi
  order_check "$_s" "$body"
  golden_check "$_s" "$body"
done

echo ""
echo "2. the CAPACITY state — a conditional clause present, the order immediately before it"
if state cap 0 cap; then
  body="$BODY"
  if hasi "$body" "capacity:"; then
    pass "cap: the CAPACITY clause really fired (the conditional path is exercised)"
  else
    fail "cap: no CAPACITY clause — this state would not prove the order survives a conditional"
  fi
  # "The order first, the detail it acts on second" is a claim in the script's own comment; it was
  # untested, and swapping the two clauses stayed green. TWO spaces: the order literal ends with a
  # space and the capacity append adds its own separator.
  if hasi "$body" "$(printf '%s' "${ORDER[3]}" | tr '[:upper:]' '[:lower:]')  ⛔ capacity:"; then
    pass "cap: the order is immediately followed by the CAPACITY clause (order first, detail second)"
  else
    fail "cap: the CAPACITY clause does not immediately follow the order — the clauses were reordered"
  fi
  order_check cap "$body"
  golden_check cap "$body"
fi

echo ""
echo "2a2. the DEAD-LANES state — a bare-shell pane, the clause that prescribes a RELAUNCH"
state dead 0 dead || true
if [ -n "$BODY" ]; then
  body="$BODY"
  if hasi "$body" "dead lanes"; then
    pass "dead: the DEAD LANES clause really fired"
  else
    fail "dead: the clause did not fire — this state proves nothing new"
  fi
  order_check dead "$body"
  golden_check dead "$body"
fi

echo ""
echo "2b. the NO-LIVE-pi state — a distinct conditional clause no pin had ever seen"
if state nolive 0 nolive; then
  body="$BODY"
  if hasi "$body" "no live pi record"; then
    pass "nolive: the NO LIVE pi RECORD clause really fired"
  else
    fail "nolive: the clause did not fire — this state proves nothing new"
  fi
  order_check nolive "$body"
  golden_check nolive "$body"
fi

echo ""
echo "2c. an ALERT plus free capacity — the FULL body with the capacity clause on it"
if state alertcap 0 alertcap; then
  body="$BODY"
  if hasi "$body" "capacity:" && hasi "$body" "needing attention."; then
    pass "alertcap: the full body carries BOTH the alert and the CAPACITY clause"
  else
    fail "alertcap: did not carry both clauses — the state proves nothing about the full-body capacity path"
  fi
  if hasi "$body" "$(printf '%s' "${ORDER[3]}" | tr '[:upper:]' '[:lower:]')  ⛔ capacity:"; then
    pass "alertcap: the order is immediately followed by the CAPACITY clause on the full body too"
  else
    fail "alertcap: the CAPACITY clause does not immediately follow the order on the full body"
  fi
  order_check alertcap "$body"
  golden_check alertcap "$body"
fi

echo ""
echo "3. the ALERT-BODY states — a routed question, an alerting lane, a queue bottleneck, an objective at risk"
if state question 1 empty; then
  body="$BODY"
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
  golden_check question "$body"
fi
# `warm` rides this loop: a fleet with an alert AND two verdicts already reported inside the hour.
# It is the ONLY state that reaches the N_KNOWN>=2 path (every other state is a cold tick), and review
# measured `[ "${N_KNOWN:-0}" -ge 2 ] && exit 0` shipping green against a matrix that had none.
for _pair in "alert:0:alert:none:ok" "bottleneck:0:empty:bottleneck:ok" "objective:0:empty:none:risk" "warm:0:warm:none:ok" "rcfail:0:empty:none:ok"; do
  IFS=: read -r _name _ask _lanes _mq _obj <<< "$_pair"
  state "$_name" "$_ask" "$_lanes" "$_mq" "$_obj" || continue
  body="$BODY"
  order_check "$_name" "$body"
  # ⛔ `rcfail`'s golden ends with the two LITERAL characters `\` `n`, and that is the EGRESS, not a
  # recording artifact: the tick's recovery branch runs `cmux send … '\n'` (single-quoted, so cmux
  # receives backslash-n and types the newline that releases a parked composer), and the double records
  # the argv it was handed verbatim. Every OTHER golden ends with `.` because only this state takes the
  # recovery branch. Do not "tidy" the tail when regenerating it, and do not read it as noise: removing
  # it would silently drop the assertion that the recovery payload is a bare newline.
  golden_check "$_name" "$body"
  if [ "$_name" = "rcfail" ]; then
    # The recovery send's PAYLOAD is the property: it is a bare newline that releases a parked
    # composer. Review appended an order-cancelling sentence to it and the suite stayed green.
    if [ "$(tail -c 2 "$STATE_HOME/.pi/agent/sessions/s1/hb-11111111-1111-1111-1111-111111111111.jsonl")" = '\n' ]; then
      pass "rcfail: the recovery send's payload is exactly the bare newline (nothing else was typed)"
    else
      fail "rcfail: the recovery send carried MORE than a newline — a second egress can carry a countermand"
    fi
    if grep -qs 'WARN send rc=' "$STATE_HOME/.pi/agent/state/orchestrator-heartbeat.log"; then
      pass "rcfail: the tick really took the rc!=0 path (the recovery branch was exercised)"
    else
      fail "rcfail: the tick never saw a failed send — this state no longer exercises the recovery branch"
    fi
  fi
done

echo ""
echo "4. proportionality: the quiet body is the shorter one, and the order clause is bounded"
quiet_body=""; full_body=""
state q1 0 empty && quiet_body="$BODY"
state q2 1 empty && full_body="$BODY"
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
# ⛔ THE CEILING IS ON THE SHORT WORDING ONLY (624 bytes shipped). The FULL clause is 713 and is not
# bounded: it rides the alert body, which is already ~4.3k. Saying "the order's wording" here would
# tell a future editor that 713 is under a 700 ceiling.
_order_ceiling=700
if [ "${#_rend}" -lt "$_order_ceiling" ]; then
  pass "the SHORT order wording is under the fixed ${_order_ceiling}-byte ceiling (${#_rend} bytes)"
else
  fail "the SHORT order wording is ${#_rend} bytes, over the fixed ${_order_ceiling}-byte ceiling — it is growing into the full text"
fi

echo ""
echo "4b. THE OVERNIGHT WORKLIST — file-backed, carried by BOTH body forms"
# ⛔ WHY THIS SECTION EXISTS. The FLEET ADVANCE order must carry the owner's open items for tonight,
# which live in a FILE ($STATE/OVERNIGHT-WORKLIST.md) so the list is data, never code. Two failures
# this pins, both measured elsewhere in this file's history: an append placed BELOW the short-form
# rebuild is LOST on every quiet beat (#1991), and a list hardcoded into the script goes stale
# silently. The list has to appear in the SHORT body AND the FULL body, and only open boxes ride.
WL_BODY=""
wl_beat(){ # wl_beat <home> <script>
  local h="$1" script="$2"
  sandbox "$h" 0 empty
  cat > "$h/.pi/agent/state/OVERNIGHT-WORKLIST.md" <<'WL'
# tonight
- [ ] land PR #1234 and name its head sha
- [x] already done, must not appear
- [ ] move #2216's pin check onto the controller path
not a checkbox line at all
WL
  EXPECT_SENDS=1
  beat "$h" "$script"
  WL_BODY="$BEAT_MSG"
}
_wl_item1="land PR #1234 and name its head sha"
_wl_item2="move #2216's pin check onto the controller path"
wl_beat "$TMP/wl_quiet" "$HB"
if [ -z "$WL_BODY" ]; then
  fail "worklist: the quiet tick produced NO message"
else
  for _t in "$_wl_item1" "$_wl_item2"; do
    if hasi "$WL_BODY" "$(printf '%s' "$_t" | tr '[:upper:]' '[:lower:]')"; then
      pass "quiet beat carries the open worklist item: $_t"
    else
      fail "quiet beat LOST the worklist item: $_t — the list does not survive the short form's MSG rebuild"
    fi
  done
  if hasi "$WL_BODY" "already done, must not appear"; then
    fail "quiet beat carries a TICKED-OFF item — only open '- [ ]' boxes ride"
  else
    pass "quiet beat omits the ticked-off item (only '- [ ]' boxes ride)"
  fi
  if hasi "$WL_BODY" "not a checkbox line at all"; then
    fail "quiet beat carries a prose line from the file — only '- [ ]' boxes ride"
  else
    pass "quiet beat omits the file's prose (only '- [ ]' boxes ride)"
  fi
  case "$WL_BODY" in
    *"OVERNIGHT WORKLIST"*) pass "the list is NAMED as the overnight worklist, not silently spliced into the standing order" ;;
    *) fail "the list is not named — a reader cannot tell a worklist item from the standing order" ;;
  esac
  case "$WL_BODY" in
    *"No alerts."*) pass "…and the body is still the SHORT form (the list rode the rebuild, not an append below it)" ;;
    *) fail "the worklist state did not take the short form, so this case proves nothing about quiet beats" ;;
  esac
fi
# The SAME list in the ALERT body: one body carrying it is the #1991 half-fix.
wl_beat "$TMP/wl_alert" "$HB"
if [ -z "$WL_BODY" ]; then
  fail "worklist: the alert tick produced NO message"
else
  if hasi "$WL_BODY" "$(printf '%s' "$_wl_item1" | tr '[:upper:]' '[:lower:]')"; then
    pass "the ALERT body carries the same worklist item"
  else
    fail "the ALERT body does not carry the worklist item — the list rides only one body form"
  fi
fi
# ⛔ SENSITIVITY: strip the interpolation from the SHORT literal only. If the quiet beat still carries
# the list, the assertions above are reading something that is not the shipped wiring.
MUTWL="$TMP/mutant-worklist.sh"
sed 's/^\(FLEETADV_SHORT=.*\)\${WL_ORDER}\(.*\)$/\1\2/' "$HB" > "$MUTWL"
if cmp -s "$HB" "$MUTWL"; then
  fail "worklist: the mutation did not apply — the sensitivity check proves nothing"
else
  wl_beat "$TMP/wl_mutant" "$MUTWL"
  if hasi "$WL_BODY" "$(printf '%s' "$_wl_item1" | tr '[:upper:]' '[:lower:]')"; then
    fail "worklist: the SHORT-literal mutant STILL carries the list — these assertions are not reading the shipped wiring"
  else
    pass "worklist: dropping \${WL_ORDER} from the short literal loses the list on a quiet beat (assertions are live)"
  fi
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
_mout=""
SUT="$MUT"
state mutant 0 empty && _mout="$BODY"
SUT="$HB"
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
# ⛔ MIN_CHECKS IS THE SHIPPED COUNT, EXACTLY — no slack. The floor assertion itself does not increment
# `checks` (it only ever fails), so the comparison is against the shipped total, and one removed check is
# red. Earlier this sat one below the total and review deleted the `rcfail` recovery-payload guard green.
MIN_CHECKS=192
if [ "$checks" -lt "$MIN_CHECKS" ]; then
  fail "only $checks assertions ran, below the shipped floor of $MIN_CHECKS — a check was removed"
fi
if [ "$failures" -eq 0 ]; then
  echo "✅ heartbeat-fleet-advance suite passed (${checks} assertions)"
  exit 0
fi
echo "❌ heartbeat-fleet-advance suite: $failures of $checks assertion(s) failed"
exit 1
