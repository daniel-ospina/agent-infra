#!/usr/bin/env bash
# product-floor.test.sh — the PRODUCT WORK FLOOR (agent-infra#2054).
#
# ⛔ THE FAILURE THIS PREVENTS. The fleet's mix being fine TODAY is not a guarantee: harness work has a
# dispatch path that bypasses PRIORITISATION (`nonblocking-dispatch.sh` backgrounds a worker by an
# orchestrator's decision — it reads no backlog, no tier and no collision pre-flight, though it DOES pass
# the same load gate via `spawn-gate.sh run_agent`, #1720) while the product channel goes through the
# queue. So the product share is guaranteed by NOTHING, and the day the queue drains into harness work the fleet
# spends its whole capacity on its own machinery while product P0/P1s sit idle — silently, because
# "dispatch is working" is still true. Measured 2026-10-18: 6 harness workers carried by that bypass
# path while the product channel carried zero.
#
# ⛔ AND THE FLOOR MUST NOT CREATE THE FAILURES IT IS NEXT TO. It is a REORDERING WITHIN ONE BATCH, so:
#   • it sits AFTER the merge-priority gate (`mp_reason`), which still wins outright;
#   • it never adds, removes or re-verifies a candidate — same `dispatched.txt` check, same pre-flight
#     verdict, same `claim_issue_acquire` (a colliding product issue is SKIPPED, never force-dispatched);
#   • a stale `candidates.product.txt` entry that is NOT in the merged backlog is never dispatched —
#     `candidates.txt` stays the authority;
#   • when the floor cannot be met it LOGS and DEGRADES (never refuses a batch), and the line carries the
#     queue-state token so "no product candidate" is distinguishable from "the intake is blind".
#
# HERMETIC: pure functions extracted from the shipped file + a hermetic sandbox for the ordering; no
# network, nothing outside $T written.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ OVERRIDABLE so the RED direction can be RE-MEASURED rather than believed:
#   LOOP=<main:scripts/orchestrator-harness/orch-loop.sh> REFRESH=<main:.../refresh-candidates.sh> \
#     bash product-floor.test.sh
LOOP="${LOOP:-$HERE/orch-loop.sh}"
REFRESH="${REFRESH:-$HERE/refresh-candidates.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/product-floor.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; SKIP=0; FAILED_LINES=""
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_LINES="$FAILED_LINES$1
"; printf '  ❌ %s\n' "$1"; }
# ⛔ A SKIPPED ASSERTION IS NOT A PASS (review cycles 30-33). Some fixtures cannot create their state on a ROOT
# box (`chmod` does not bind root) — and `chmod`+`ck … 0` counted a "skipped" line as a PASS, so `N passed, 0
# failed` could not distinguish "every pin ran" from "some did not". Skips are now counted separately, an arm
# that replaces N assertions prints N skip lines (so PASS+SKIP is the assertion TOTAL on every platform), and
# `MIN_CHECKS` reddens if that total drops — a deleted pin, or an assertion quietly converted into a skip.
skipped() { SKIP=$((SKIP+1)); printf '  ⏭️  %s\n' "$1"; }
ck() {
  case "$1" in
    *"(skipped)"*) skipped "$1"; return 0 ;;
  esac
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

[ -f "$LOOP" ] || { echo "❌ missing $LOOP"; exit 2; }
[ -f "$REFRESH" ] || { echo "❌ missing $REFRESH"; exit 2; }

# ⛔ THE FUNCTIONS ARE EXTRACTED FROM THE SHIPPED FILE, so this suite executes the code the daemon runs
# rather than a copy that can drift. A missing function is a RED, not a skip.
FNS="$T/fns.sh"
{
  sed -n '/^pc_state_note() {/,/^}/p' "$LOOP"
  sed -n '/^floor_norm() {/,/^}/p' "$LOOP"
  sed -n '/^floor_order() {/,/^}/p' "$LOOP"
  sed -n '/^floor_choose_order() {/,/^}/p' "$LOOP"
} > "$FNS"
[ -s "$FNS" ] && grep -q 'floor_norm()' "$FNS" && grep -q 'floor_order()' "$FNS" && grep -q 'floor_choose_order()' "$FNS"
SETUP_RC=$?
ck "P0 (setup) the floor functions extract from the shipped orch-loop.sh" $SETUP_RC
# shellcheck source=/dev/null
. "$FNS" || { echo "❌ $FNS failed to source"; exit 2; }

prod() { printf '%s\n' "$@" > "$T/product.txt"; }
all()  { printf '%s\n' "$@" > "$T/all.txt"; }
order() { floor_order "$1" "$T/product.txt" "$T/all.txt" 2>/dev/null; }

echo
echo "── P1: a BATCH=2 dispatch with a dispatchable product candidate contains one ──────"
prod 34
all 12 34 56
GOT="$(order 1 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "34 12 56" ]
ck "P1 [RED→GREEN] the product candidate is moved to the HEAD of the order (got '$GOT')" $?

echo
echo "── P2: floor=0 is EXACTLY today's behaviour (no reordering at all) ────────────────"
GOT="$(order 0 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "12 34 56" ]
ck "P2 [RED→GREEN] floor=0 leaves the severity/FIFO order untouched (got '$GOT')" $?

echo
echo "── P3: the floor is bounded by the batch size, and normalised ─────────────────────"
GOT="$(floor_norm 5 2)"; [ "$GOT" = "2" ]
ck "P3 [RED→GREEN] a floor above the batch is CLAMPED to the batch (got '$GOT')" $?
GOT="$(floor_norm '' 2)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] an unset floor takes the default 1 (got '$GOT')" $?
GOT="$(floor_norm 'abc' 2)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] a non-numeric floor falls back to the default, never to 0-or-abort (got '$GOT')" $?
GOT="$(floor_norm 0 2)"; [ "$GOT" = "0" ]
ck "P3 [RED→GREEN] an explicit 0 DISABLES the floor (it is a valid setting, not a missing one)" $?
GOT="$(floor_norm 3 1)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] a floor above the batch is CLAMPED to the batch" $?
# ⛔ AND A BATCH OF 0 IS READ AS 1 (review cycle 36, P2). This arm is the premise `install.sh` cites when it ACCEPTS
# `BATCH=0 PRODUCT_FLOOR=1` ("floor_norm reads a batch of 0 as 1") and `selftest.sh` pins that acceptance — but the
# loop-side half was measured by nothing, so dropping `|0*` left the suite green while the same config silently
# turned the floor OFF (floor 1 clamped to 0 = disabled), which is exactly what the README says must not happen.
GOT="$(floor_norm 1 0)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] a BATCH of 0 is read as 1, so the floor stays ENABLED (the premise install.sh accepts it on)" $?
GOT="$(floor_norm 9 0)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] ... and a larger floor is clamped to that 1, not to 0" $?
GOT="$(floor_norm 1 '')"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] ... and an EMPTY batch behaves the same way" $?
# ⛔ AND A VALUE THAT WRAPS IN ARITHMETIC MUST NOT TURN THE FLOOR OFF (review cycle 38, P2). `$(( 10#$raw ))` on an
# all-digit 20-digit value wraps NEGATIVE, and `[ "$f" -ge 0 ] || f=1` is the only arm that catches it — deleting
# that arm leaves `floor_norm` returning -1, which closes the block's `FLOOR_N -gt 0` gate so the floor is DISABLED
# for the cycle with NO log line at all. The knob is reachable past install.sh's digit check through $ENV_FILE, so
# this is the "silently switch the guarantee off" state both the docstring and the README say cannot happen.
GOT="$(floor_norm 18446744073709551615 2)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] a PRODUCT_FLOOR whose arithmetic wraps NEGATIVE is read as 1, not as a negative floor (got '$GOT')" $?
GOT="$(floor_norm 9223372036854775808 2)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] ... and so is a value one past the 64-bit signed maximum (got '$GOT')" $?
# ⛔ THE FLOOR IS A COUNT, NOT A PREFERENCE (review cycle 9, P1). Every ordering fixture fed a product
# queue with AT MOST `floor` entries, so deleting `[ "$took" -lt "$floor" ] || break` — which makes the
# floor "all product first" and starves the harness channel for a whole batch — left the suite at 111/0.
# Here TWO product candidates are available for a floor of ONE, and exactly one may lead.
printf '34\n56\n' > "$T/f3p.txt"; printf '12\n34\n56\n' > "$T/f3a.txt"
GOT="$(floor_order 1 "$T/f3p.txt" "$T/f3a.txt" | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "34 12 56" ]
ck "P3 [RED→GREEN] floor=1 with TWO product candidates orders exactly ONE of them first (got '$GOT')" $?
GOT="$(floor_order 0 "$T/f3p.txt" "$T/f3a.txt" | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "12 34 56" ]
ck "P3 [RED→GREEN] floor=0 orders the backlog untouched (got '$GOT')" $?
GOT="$(floor_order 2 "$T/f3p.txt" "$T/f3a.txt" | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "34 56 12" ]
ck "P3 [RED→GREEN] floor=2 takes BOTH product candidates, then the rest (got '$GOT')" $?
# ⛔ EXACT MATCH, NOT A PREFIX (review cycle 11, P2). Loosening `grep -qx` to `grep -q` on the backlog
# check lets a product entry that is a PREFIX of a backlog line be emitted as a dispatch candidate —
# product `1` against backlog `12 34 56` printed `1 12 34 56`, i.e. the loop would be handed issue #1,
# which is not in the backlog — and every fixture shared an exact match or no prefix, so 120/0 held.
# The counter's `PB` walk has had this pin since cycle 7; the ordering half did not.
printf '1\n' > "$T/f4p.txt"; printf '12\n34\n56\n' > "$T/f4a.txt"
GOT="$(floor_order 1 "$T/f4p.txt" "$T/f4a.txt" | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "12 34 56" ]
ck "P4 [RED→GREEN] a product entry that only PREFIXES a backlog line is not emitted as a candidate (got '$GOT')" $?
# The shortfall line shares a sentence with the count line, and cycle 9 found it printing a SECOND
# denominator (`$PB/$FLOOR_N in this batch`) for a phrase that means "out of the batch". Pinned
# structurally — the line must name `batch=` and `floor=` — rather than by reproducing its prose, which
# has been reworded twice.
grep -q 'product-floor unmet (product=\$PB batch=\$K floor=\$FLOOR_N' "$LOOP"
ck "P6 [RED→GREEN] the shortfall line names its two denominators (batch=K, floor=FLOOR_N), not one phrase twice" $?
# ⛔ THIS ASSERTION WAS DEAD, AND THE SUITE READ 120/0 ANYWAY (review cycle 11, P2). Its `$?` was the
# return of the `ck` call four lines above (a `printf`, rc 0), so the label claimed the BATCH=1 clamp was
# pinned while the comparison `[ "$GOT" = "1" ]` at the top of this section was never graded: inverting it
# to `= 999` left 120 passed, 0 failed. The clamp is now re-measured HERE, inside its own assertion, and the
# label names the value so a reader can see what was graded.
GOT="$(floor_norm 3 1)"; [ "$GOT" = "1" ]
ck "P3 [RED→GREEN] a floor above a BATCH=1 is clamped to 1 (the floor can never exceed the batch) (got '$GOT')" $?

echo
echo "── P4: ordering never invents, duplicates or resurrects a candidate ───────────────"
prod 34 34
all 12 34 56
GOT="$(order 1 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "34 12 56" ]
ck "P4 [RED→GREEN] a duplicated product entry appears ONCE (got '$GOT')" $?
prod 99
all 12 34 56
GOT="$(order 1 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "12 34 56" ]
ck "P4 [RED→GREEN] a product entry ABSENT from the backlog is never dispatched (got '$GOT')" $?
prod 34 12
all 12 34 56
GOT="$(order 2 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "34 12 56" ]
ck "P4 [RED→GREEN] up to <floor> product candidates take the head, in their own order (got '$GOT')" $?
# ⛔ A DUPLICATE INSIDE THE HEAD, NOT ONLY IN THE TAIL (cycle-1 review, P2). The head loop had no
# de-duplication of its own, so `floor_order 2` over product `[34 34]` emitted `34 34 12 56` — two slots
# spent on one issue, which makes the batch shorter than BATCH and leaves only the dispatch loop's own
# `dispatched.txt` arm between that and a duplicate dispatch. The floor=1 case below passed by luck (the
# `took < floor` break, not a dedupe), which is exactly the false green this assertion closes.
prod 34 34
all 12 34 56
GOT="$(order 2 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "34 12 56" ]
ck "P4 [RED→GREEN] a repeated product entry never takes a SECOND floor slot (got '$GOT')" $?
all 12 34 56
rm -f "$T/product.txt"
# ⛔ THE STATUS IS CAPTURED BEFORE THE FORMATTING PIPELINE (this lane's cycle-3 review, P3). A pipeline's
# exit status is its LAST command, so `GOT="$(order 1 | … | sed …)"; RC=$?` recorded `sed`'s status — 0
# for any input, with no `pipefail` here — and the "never an abort" half of the assertion could not fail.
# Measured: `X="$(bash -c 'exit 7' | cat)"; echo $?` → 0. Only the order comparison discriminated.
ORDER_OUT="$(order 1)"; RC=$?
GOT="$(printf '%s\n' "$ORDER_OUT" | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "12 34 56" ] && [ "$RC" = "0" ]
ck "P4 [RED→GREEN] a MISSING product file degrades to today's order, rc=0 (never an abort) (got '$GOT' rc=$RC)" $?
: > "$T/product.txt"; all 12 34 56
GOT="$(order 1 | tr '\n' ' ' | sed 's/ $//')"
[ "$GOT" = "12 34 56" ]
ck "P4 [RED→GREEN] an EMPTY product file is the same degraded order (got '$GOT')" $?

echo
echo "── P5: no helper exists only for this suite to drive (dead code is not coverage) ──"
# ⛔ `floor_split` USED TO LIVE HERE, and it was DEAD (review cycle 2, P2): `git grep` found the
# definition, its docstring and these assertions, and NO shipped caller — the operator's split is printed
# by `write_product_queues` in refresh-candidates.sh, and the dispatch indicator counts `PB` inline in
# orch-loop.sh. A function whose only consumer is its own test is coverage that cannot fail when the
# daemon regresses, so it is deleted rather than kept green. This assertion is the other half: it refuses
# a future helper that nothing but this file calls.
DEAD=""
# ⛔ GENERIC OVER EVERY `floor_*` DEFINITION IN THE SHIPPED FILE, not over a list this suite keeps: a
# hardcoded list would let the NEXT dead helper through (the deleted one was itself on such a list, as the
# function the test drove). `DEFS` must be non-empty or the assertion is vacuous.
DEFS="$(grep -oE '^floor_[a-z_]+\(\)' "$LOOP" 2>/dev/null | sed 's/()$//' | tr '\n' ' ')"
for _fn in $DEFS; do
  # A CALL, not a mention: the definition reads `name() {`, so a call is the name followed by whitespace on
  # a line that is not a comment. `floor_split` scored 0 here before it was deleted — that is the shape
  # this assertion exists to catch (a helper that only its own test drives).
  _calls="$(grep -v '^[[:space:]]*#' "$LOOP" 2>/dev/null | grep -c -E "(^|[^[:alnum:]_])${_fn}[[:space:]]" 2>/dev/null || true)"
  [ "${_calls:-0}" -ge 1 ] || DEAD="$DEAD $_fn"
done
[ -n "$DEFS" ] && [ -z "$DEAD" ]
ck "P5 [RED→GREEN] every floor helper has a shipped caller, not just a definition (defs:$DEFS uncalled:$DEAD)" $?

echo
echo "── P6: the floor sits AFTER merge priority, and an unmet floor DEGRADES ─────────────"
# ⛔ POSITION IS THE CONTRACT (indicator (c)): the floor may not delay a batch, so its ORDERING CODE must
# come after the merge-priority gate's decision (`GATE_WHY`). A text pin is the honest instrument here —
# the gate is driven by its own suite, and re-driving it would be a second implementation of it.
# ⛔ ANCHORED TO THE CODE, NOT TO A PHRASE (this lane's cycle-3 review, P2). The pin used to grep
# `product-floor unmet`, whose FIRST match in the shipped loop is a COMMENT 100 lines below the code it
# named — so moving `FLOOR_N`/`ORDER_FILE` above `mp_reason` (the one mutation this assertion exists to
# reject) left the pin GREEN. This is the same shape P8 already fixed for its own pin (`done < \$ORDER_FILE`
# matched the comment quoting it): anchor to the line that DECIDES, and assert BOTH lines, because
# `ORDER_FILE` is what the dispatch loop actually reads and `FLOOR_N` is what produces it.
LINE_GATE="$(grep -n '^[[:space:]]*GATE_WHY="\$(mp_reason' "$LOOP" | head -1 | cut -d: -f1)"
LINE_FLOORN="$(grep -n '^[[:space:]]*FLOOR_N="\$(floor_norm' "$LOOP" | head -1 | cut -d: -f1)"
LINE_ORDER="$(grep -n '^[[:space:]]*ORDER_FILE="\$(floor_choose_order' "$LOOP" | head -1 | cut -d: -f1)"
[ -n "$LINE_GATE" ] && [ -n "$LINE_FLOORN" ] && [ -n "$LINE_ORDER" ] \
  && [ "$LINE_FLOORN" -gt "$LINE_GATE" ] && [ "$LINE_ORDER" -gt "$LINE_GATE" ]
ck "P6 [RED→GREEN] the floor's ORDERING code sits AFTER the merge-priority gate (gate=$LINE_GATE FLOOR_N=$LINE_FLOORN ORDER_FILE=$LINE_ORDER)" $?
# ⛔ AND IT MUST CARRY THE QUEUE-STATE TOKEN (indicator (b)): without it, `product-floor unmet` on a
# blind intake reads as "there is no product work", which is the #2042/#1931 masking failure.
# ⛔ BOTH GREPS WERE UNSATISFIABLE-BY-MUTATION (review cycle 15, P2): an unanchored `product-floor unmet` is
# satisfied by the COMMENT and `queue=$(queue_state_token)` by the cycle header, so stripping the token from
# all three unmet lines left this pair green. Anchored to the lines that PRINT: every `[dispatch] product-floor
# unmet` echo must carry the token.
_unmet_lines="$(grep -E '^[[:space:]]*echo "\[dispatch\] product-floor unmet' "$LOOP" 2>/dev/null || :)"
_unmet_n="$(printf '%s\n' "$_unmet_lines" | grep -c . 2>/dev/null || :)"
_unmet_notok="$(printf '%s\n' "$_unmet_lines" | grep -v 'queue=\$(queue_state_token)' 2>/dev/null || :)"
[ "${_unmet_n:-0}" -ge 3 ] && [ -z "$_unmet_notok" ]
ck "P6 [RED→GREEN] the unmet line names the queue state, so blindness is not read as 'no product work'" $?
# An unmet floor must not close the lane: the same branch must still reach the batch dispatch.
grep -q 'product-floor unmet' "$LOOP" && ! grep -q 'exit .*product-floor' "$LOOP"
ck "P6 [RED→GREEN] an unmet floor NEVER refuses the batch (no exit on the unmet path)" $?
# ⛔ AND IT MAY NOT EMPTY THE BATCH EITHER (cycle-1 review, P1): "log and degrade" means the issues this
# pass already selected are still dispatched. The failure to exclude is `: > "$O/.batch"; K=0` on the
# unmet path — dispatch then stalls until a product candidate appears, which is exactly the
# don't-cap-the-fleet rule the issue states. A spelling pin, stated as one: the unmet arms contain no
# batch-truncation or counter reset.
# ⛔ AND THE DISPATCH PATH ITSELF IS NOT THE GATE (review cycle 6, P2). Scanning forward from the string
# `product-floor unmet` can only see code INSIDE the reporting block, so the three mutations that matter —
# `: > "$O/.batch"; K=0` right after `done < "$ORDER_FILE"`, an `exit 0` there, and making the reporting
# block's first condition depend on `PB` (a floor that gates dispatch, which #2054 forbids outright) —
# all left the suite GREEN. Pinned from the LOOP side: no `PB`, no batch truncation and no `exit` between
# the order read and the reporting block, and `FLOOR_N`/`ORDER_FILE` derived from the OPERATOR's knob.
_lord="$(grep -n '^[[:space:]]*done < "\$ORDER_FILE"' "$LOOP" | head -1 | cut -d: -f1)"
_lrep="$(grep -n 'AN UNMET FLOOR LOGS AND DEGRADES' "$LOOP" | head -1 | cut -d: -f1)"
case "$_lord$_lrep" in ''|*[!0-9]*) P6L=1 ;; *) P6L=0 ;; esac
ck "P6 (setup) the order read and the reporting block are locatable (order=$_lord report=$_lrep)" $P6L
_between="$(awk -v s="${_lord:-1}" -v e="${_lrep:-0}" 'NR>s && NR<e && (/(^|[^A-Za-z_])PB([^A-Za-z0-9_]|$)/ || /: > "\$O\/\.batch"/ || /^[[:space:]]*K=0/ || /^[[:space:]]*exit /) {print NR": "$0}' "$LOOP")"
[ -z "$_between" ]
ck "P6 [RED→GREEN] nothing between the order read and the report can truncate the batch, reset K, exit, or make dispatch depend on PB (got '${_between:-'<none>'}')" $?
# ⛔ AND THE BATCH IS DISPATCHED ON `.batch` ALONE (review cycle 8, P1). The window above stops at the
# report marker, and the report sits BEFORE the dispatch — so `if [ -s "$O/.batch" ]; then` is the line a
# "the floor refuses the batch" edit would land on, and nothing read it. Measured: adding
# `[ "${FLOOR_N:-0}" -gt 0 ] && [ ! -s candidates.product.txt ] && { : > .batch; K=0; }` immediately after
# the block left the suite at 106/0, and the same slot with `exit 0` did too — a fleet that dispatches
# nothing, reported green. Pinned as an exact condition and as the absence of floor terms around it.
grep -Eq '^[[:space:]]*if \[ -s "\$O/\.batch" \]; then[[:space:]]*$' "$LOOP"
ck "P6 [RED→GREEN] the batch is dispatched on .batch ALONE — the dispatch condition carries no floor term" $?
_disp="$(grep -n '^[[:space:]]*if \[ -s "\$O/\.batch" \]; then[[:space:]]*$' "$LOOP" | head -1 | cut -d: -f1)"
case "$_disp" in ''|*[!0-9]*) P6D=1 ;; *) P6D=0 ;; esac
ck "P6 (setup) the dispatch condition is locatable (disp=$_disp)" $P6D
# The report block's own text names FLOOR_N legitimately, so the window starts at its CLOSING `fi` — the
# FOUR-space one that closes the `if [ "${FLOOR_N:-0}" -gt 0 ]` guard.
_repend="$(awk -v s="${_lrep:-0}" 'NR>s && /^    fi$/ {print NR; exit}' "$LOOP")"
case "$_repend" in ''|*[!0-9]*) P6E=1 ;; *) P6E=0 ;; esac
ck "P6 (setup) the reporting block's closing fi is locatable (repend=$_repend)" $P6E
_dend="$(awk -v s="${_disp:-0}" 'NR>s && /^    fi$/ {print NR; exit}' "$LOOP")"
case "$_dend" in ''|*[!0-9]*) P6B=1 ;; *) P6B=0 ;; esac
ck "P6 (setup) the dispatch body's closing fi is locatable (disp=$_disp end=$_dend)" $P6B
# ⛔ ONE WINDOW, FROM THE END OF THE REPORT TO THE END OF THE DISPATCH BODY (review cycle 15, P2). The old
# `_between2` scan ran from the report's closing `fi` to the dispatch CONDITION — which are ADJACENT lines
# (measured 2864 → 2865), so the window was EMPTY and its assertion could never fail, while its label claimed
# to cover "between the report and the dispatch". A gate inserted in that gap was therefore covered by
# nothing. Scanning the report's close through the dispatch body instead makes the window real (its width is
# asserted below) and still catches the two positions that matter: a gate spliced in before the dispatch
# condition, and a floor gate as the body's first statement (the cycle-9 finding).
case "$_repend" in ''|*[!0-9]*) P6W=1 ;; *) P6W=$(( ${_dend:-0} - _repend )) ;; esac
[ "${P6W:-0}" -gt 1 ]
ck "P6 (setup) the report→dispatch window is non-empty, so the scan below is not vacuous (width=${P6W:-?})" $?
_body="$(awk -v s="${_repend:-1}" -v e="${_dend:-0}" 'NR>s && NR<e && (/candidates\.product\.txt/ || /: > "\$O\/\.batch"/ || /^[[:space:]]*K=0/ || /^[[:space:]]*exit / || /FLOOR_N/) {print NR": "$0}' "$LOOP")"
[ -z "$_body" ]
ck "P6 [RED→GREEN] from the end of the report through the dispatch BODY nothing gates on the floor, empties the batch, resets K or exits (got '${_body:-'<none>'}')" $?
grep -Eq '^[[:space:]]*FLOOR_N="\$\(floor_norm "\$\{PRODUCT_FLOOR:-[0-9]+\}"' "$LOOP"
ck "P6 [RED→GREEN] FLOOR_N is derived from PRODUCT_FLOOR (the operator's knob), not from a literal" $?
grep -Eq '^[[:space:]]*ORDER_FILE="\$\(floor_choose_order' "$LOOP" && grep -q 'floor_choose_order "\$O" "\$FLOOR_N"' "$LOOP"
ck "P6 [RED→GREEN] and the order is chosen for that FLOOR_N" $?
# The UNKNOWN arm must not claim an absence it did not measure (the #2042/#1931 masking shape).
awk '/candidates.product.txt is absent or empty/{print}' "$LOOP" | grep -q 'product class UNKNOWN'
ck "P6 [RED→GREEN] the unreadable-class arm says UNKNOWN, not 'no product candidate'" $?
# ⛔ AND IT REPEATS THE RECORDED REASON INSTEAD OF ASKING THE OPERATOR (review cycle 2, P2): on a repo
# that is simply not a product repo this arm fired EVERY pass with a question the refresh had already
# answered, in the same words as a real listing failure.
grep -q 'state/product-class' "$LOOP"
ck "P6 [RED→GREEN] the unmet line reads the RECORDED product class (not a re-derivation, not a question)" $?
awk '/product-floor N\/A/{print}' "$LOOP" | grep -q 'because \${PC_WHY}'
ck "P6 [RED→GREEN] the N/A line reports the RECORDED reason, so a routine case is self-explanatory" $?
grep -q 'NOT-A-PRODUCT-REPO\*)' "$LOOP"
ck "P6 [RED→GREEN] ... and the N/A arm is SELECTED BY the recorded NOT-A-PRODUCT-REPO class" $?
grep -q 'UNRECORDED' "$LOOP"
ck "P6 [RED→GREEN] ... and an ABSENT record is named UNRECORDED, not silently read as 'no product work'" $?
# ⛔ A MEASURED-EMPTY QUEUE MUST NOT BE REPORTED AS UNKNOWN (review cycle 2b, P2). `OK product=0` is a
# MEASUREMENT (the split ran, every candidate is harness); only the unread reasons are UNKNOWN. The two
# used to share one arm, so the routine all-harness pass printed "could not be counted" beside its own
# `reason=OK product=0` — and an operator grepping UNKNOWN for a blind intake got a false positive every
# pass. Assert the OK arm EXISTS and that its line does not claim UNKNOWN.
awk '/^[[:space:]]*OK\*\)/{f=1;next} f&&/^[[:space:]]*\*\)/{f=0} f' "$LOOP" | grep -q 'no dispatchable product candidate'
ck "P6 [RED→GREEN] a MEASURED empty product queue has its own arm (OK*, not the UNKNOWN one)" $?
# ⛔ EXISTENCE AND CONTENT ARE ONE CONDITION (review cycle 3, P3): with the content check alone, a file
# with NO `OK*)` arm extraction produced 0 lines, grep found nothing, and the assertion reported PASS while
# testing nothing — a no-op gate for exactly the state it is named after (measured: green on the pre-fix
# file). Folding them means a missing arm cannot pass silently.
OKB="$(awk '/^[[:space:]]*OK\*\)/{f=1;next} f&&/^[[:space:]]*\*\)/{f=0} f' "$LOOP")"
{ [ -n "$OKB" ] && ! grep -q 'product class UNKNOWN' <<<"$OKB"; }
ck "P6 [RED→GREEN] ... and that arm does NOT claim UNKNOWN, which is reserved for an unread class" $?

echo
echo "── P7: the refresh writes the two queues; the merged backlog stays the authority ───"
grep -q 'candidates.product.txt' "$REFRESH"
ck "P7 [RED→GREEN] refresh-candidates.sh writes a product queue" $?
grep -q 'candidates.harness.txt' "$REFRESH"
ck "P7 [RED→GREEN] refresh-candidates.sh writes a harness queue" $?
# ⛔ PRODUCT IS A PROPERTY OF THE REPO, NOT A LABEL-INVENTED CATEGORY: the class is "the target repo is a
# product repo AND the issue is not labelled `harness`", so a harness issue in a product repo cannot
# satisfy the floor and a product issue in a harness repo cannot either.
grep -q 'PRODUCT_REPOS' "$REFRESH"
ck "P7 [RED→GREEN] the product class is configured by repo (PRODUCT_REPOS), not inferred from titles" $?
# ⛔ THE KNOB THE WHOLE GUARANTEE RESTS ON MUST BE DISCOVERABLE (this lane's cycle-3 review, P3).
# `PRODUCT_REPOS` decides "is this repo product?" and the loop reports `product-floor N/A` off it — but it
# appeared ONLY inside the `PRODUCT_FLOOR` cell, `install.sh` neither renders nor validates it (a
# comma-list cannot pass the numeric validator), and its default was written down only in
# ARCHITECTURE.md. So the one input an operator must change to point the floor at their own product had
# no documented home. Pin the §Tuning ROW, not the phrase: a row must exist, name the list form, and say
# it is `$ENV_FILE`-only — the three things an operator needs and none of which is inferable.
grep -qE '^\| `PRODUCT_REPOS` \|' "$HERE/README.md" \
  && awk '/^\| `PRODUCT_REPOS` \|/{f=1} f{print}' "$HERE/README.md" | head -1 | grep -q 'comma-separated' \
  && awk '/^\| `PRODUCT_REPOS` \|/{f=1} f{print}' "$HERE/README.md" | head -1 | grep -q 'ENV_FILE'
ck "P7 [RED→GREEN] README §Tuning carries a PRODUCT_REPOS row (comma-separated, \$ENV_FILE-only)" $?
grep -q -- '--label harness' "$REFRESH"
ck "P7 [RED→GREEN] the harness class comes from the harness LABEL, read from the API" $?
# ⛔ ANCHORED TO THE ASSIGNMENT (this lane's cycle-2 review, P1). A bare `grep PRODUCT_FLOOR` is
# satisfied by the COMMENT above the knob that names it, so a mutation deleting the assignment itself
# — leaving the floor permanently at its default — kept this pin GREEN.
grep -Eq '^[[:space:]]*PRODUCT_FLOOR="\$\{PRODUCT_FLOOR:-[0-9]+\}"[[:space:]]*$' "$LOOP"
ck "P7 [RED→GREEN] orch-loop.sh assigns PRODUCT_FLOOR from the environment (an anchored code line, not a mention)" $?
# ⛔ AND THE REFRESH'S SPLIT IS DRIVEN, NOT GREPPED (cycle-1 review, P1). Two defects survived the
# grep-only version: the inline block called a helper that lives in orch-loop.sh — the refresh
# runs as a CHILD process and never sources it, so the operator's line printed NO COUNTS on every pass
# under `2>/dev/null`; and the failed-listing polarity (a read that did not answer must classify
# everything as HARNESS, never manufacture product work) had no assertion at all, so inverting it left
# the suite green. `write_product_queues` is extracted from the shipped refresh and driven here, both
# arms, with a stubbed `rest_list`.
WFNS="$T/wfns.sh"
# The writer's four "everything is harness" arms go through `wpq_degrade` (review cycle 7, P1), so the
# fixture takes BOTH: extracting only the writer leaves the helper unbound and every degrade arm dies on
# `command not found` — which looked exactly like "the arm says nothing" when this was first wired.
{ sed -n '/^wpq_writable() {/,/^}/p' "$REFRESH"; sed -n '/^wpq_fallback() {/,/^}/p' "$REFRESH"; sed -n '/^write_record() {/,/^}/p' "$REFRESH"; sed -n '/^record_state_note() {/,/^}/p' "$REFRESH"; sed -n '/^wpq_degrade() {/,/^}/p' "$REFRESH"; } > "$WFNS"
sed -n '/^write_product_queues() {/,/^}/p' "$REFRESH" >> "$WFNS"
[ -s "$WFNS" ] && grep -q 'write_product_queues()' "$WFNS" && grep -q 'wpq_degrade()' "$WFNS"
ck "P7 (setup) the refresh's split function extracts from the shipped file" $?
wk() { # <O> <OR> <PRODUCT_REPOS> <rest_list-rc> [harness-list] [window-filled] [core-now] [core-reserve] [core-per-candidate]
  local o="$1" repo="$2" pre="$3" rc="$4" lst="${5:-}" wf="${6:-0}" cn="${7:-}" cr="${8:-}" cpc="${9:-}"
  (
    O="$o"; CORE_NOW="$cn"; CORE_RESERVE="$cr"; REST_WINDOW_FILLED="$wf"
    # CORE_PER_CANDIDATE is the PER-CANDIDATE pre-flight estimate, not a page cost. It is set here only
    # so a fixture can prove the listing's budget bound does NOT scale with it (review cycle 3, P2).
    CORE_PER_CANDIDATE="$cpc"
    rest_list() {
      # The shipped helper sets REST_WINDOW_FILLED on saturation; a stub must model that seam or the
      # truncation arm below would be untestable (and the polarity it guards unproven).
      REST_WINDOW_FILLED="$wf"
      [ "$rc" = "0" ] || return 1
      printf '%s\n' $lst
    }
    # shellcheck source=/dev/null
    . "$WFNS" || exit 1
    write_product_queues "$o" "$repo" "$pre"
  ) 2>&1
}
pcwhy() { head -1 "$1/state/product-class" 2>/dev/null; }
mkdir -p "$T/wo"; printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTW="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56")"
PRODW="$(tr '\n' ' ' < "$T/wo/candidates.product.txt" | sed 's/ $//')"
HARNW="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" | sed 's/ $//')"
[ "$PRODW" = "34" ] && [ "$HARNW" = "12 56" ]
ck "P7 [RED→GREEN] a SUCCESSFUL label listing splits the backlog: product='$PRODW' harness='$HARNW'" $?
case "$OUTW" in *"split: product 1 harness 2"*) W1=0 ;; *) W1=1 ;; esac
ck "P7 [RED→GREEN] the split line CARRIES ITS COUNTS (got '$OUTW')" $W1
# ⛔ EVERY ARM RECORDS WHAT IT DECIDED, and the loop REPEATS it (review cycle 2, P2). Without the record
# the dispatch line printed a QUESTION the refresh had already answered — the same words for a routine
# NOT-A-PRODUCT-REPO pass and for a real listing failure, which is how the real one stops being read.
case "$(pcwhy "$T/wo")" in OK*product=1*) W1R=0 ;; *) W1R=1 ;; esac
ck "P7 [RED→GREEN] a SUCCESSFUL pass RECORDS its outcome in state/product-class (got '$(pcwhy "$T/wo")')" $W1R
# ⛔ AND THE RECORD'S FORMAT IS PINNED, BOTH FIELDS (review cycle 23, P2). Cycle 22's cross-check consumes
# `harness=` as well as `product=`, but nothing pinned the writer's FORMAT: dropping ` harness=%s` from the
# writer left the suite green, and the loop then silently fell back to the product-only check (`[ -n "$_rec_h" ]`
# skips the harness comparison when the field is absent) — so the stale-split publication cycle 22 exists to
# prevent became reachable with every gate green. Pinned as the whole record, driven, not grepped.
case "$(pcwhy "$T/wo")" in "OK product=1 harness=2") W1F=0 ;; *) W1F=1 ;; esac
ck "P7 [RED→GREEN] the record is EXACTLY 'OK product=<n> harness=<m>' — both numbers the loop cross-checks (got '$(pcwhy "$T/wo")')" $W1F
grep -Fq 'write_record "$o" "OK product=$wpq_prod harness=$wpq_harn"' "$REFRESH"
ck "P7 [RED→GREEN] ... and the writer's printf carries BOTH fields, in that form" $?
# ⛔ THE WARNING LOOKS BEFORE IT SPEAKS (review cycle 12, P2). It claimed the floor would carry "a PREVIOUS
# pass's record" even when NO record exists (an `$O` that cannot hold a `state/` at all), which is a
# different thing for an operator to chase and is what the loop reports as UNRECORDED. Both cases driven.
# ⛔ AND BOTH GUARD ON THE OBSERVABLE (review cycle 33, P2). As ROOT, `chmod 500`/`chmod 400` do not deny the
# write, the fixture cannot create the state it grades, and the two assertions FAILED for an environment reason
# (the same trap this file fixed for four other fixtures). Skipped, never failed, and never silently counted as a
# pass: on a root box both are reported as SKIPS and the MIN_CHECKS floor still requires the executed total.
mkdir -p "$T/wns"; printf '12\n34\n' > "$T/wns/candidates.txt"; chmod 500 "$T/wns"
mkdir -p "$T/wns2/state"; printf '12\n34\n' > "$T/wns2/candidates.txt"
# The FILE is made read-only, not the directory: `> existing-file` truncation needs write permission on the
# file, not on its directory, so a 500-directory left the PENDING write succeeding and the warning unprinted.
printf 'OK product=0 harness=2\n' > "$T/wns2/state/product-class"; chmod 400 "$T/wns2/state/product-class"
if [ ! -w "$T/wns" ]; then
  OUTNS="$(wk "$T/wns" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12")"
  chmod 700 "$T/wns" 2>/dev/null || :
  case "$OUTNS" in *"NO record at all"*) N1=0 ;; *) N1=1 ;; esac
  ck "P7 [RED→GREEN] an unwritable state/ with NO record says so instead of promising a PREVIOUS one (got '$OUTNS')" $N1
else
  chmod 700 "$T/wns" 2>/dev/null || :
  ck "P7 (skipped) cannot make state/ unwritable on this box (running as root?)" 0
fi
if [ ! -w "$T/wns2/state/product-class" ]; then
  OUTWS="$(wk "$T/wns2" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12")"
  chmod 600 "$T/wns2/state/product-class" 2>/dev/null || :
  case "$OUTWS" in *"the record already on disk"*) N2=0 ;; *) N2=1 ;; esac
  ck "P7 [RED→GREEN] ... and with a record PRESENT it names THAT record (measured, not assumed) (got '${OUTWS:0:140}')" $N2
  # ⛔ AND THE READ-ONLY TARGET IS THE OTHER HALF OF THE WRITABILITY PROBE (review cycle 34, P2): the directory
  # half was pinned by the unwritable-`state/` fixture, so deleting the TARGET clause from `wpq_writable` left the
  # suite green while the shipped writer printed `Permission denied` twice per pass. The claim is the same one the
  # pass-log fixtures make: no shell diagnostic reaches the operator.
  case "$OUTWS" in *"Permission denied"*|*"Read-only"*|*"not permitted"*|*"Is a directory"*) N3=1 ;; *) N3=0 ;; esac
  ck "P7 [RED→GREEN] ... and a READ-ONLY record produces NO shell error on the operator's output (got '$(printf '%s' "$OUTWS" | head -c 120)')" $N3
else
  chmod 600 "$T/wns2/state/product-class" 2>/dev/null || :
  ck "P7 (skipped) cannot make the record read-only on this box (running as root?) — names the record on disk" 0
  ck "P7 (skipped) ... — no shell error on the operator's output" 0
fi
# A split that RAN and found nothing is `OK product=0` — the measurement the dispatch line must repeat as
# a measured absence rather than as an unread class (review cycle 2b, P2).
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 34 56" >/dev/null
PROD0="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PROD0" = "0" ] && case "$(pcwhy "$T/wo")" in OK*product=0*) W1Z=0 ;; *) W1Z=1 ;; esac
ck "P7 [RED→GREEN] an all-harness backlog records OK product=0 (a MEASUREMENT), never NOT-A-PRODUCT-REPO (got '$(pcwhy "$T/wo")')" "${W1Z:-1}"
# ⛔ THE FAILED-READ ARM IS THE ONE THAT CAN INVENT WORK: an unanswered listing must leave the product
# queue EMPTY (everything harness) and say why.
# ⛔ SEED A STALE SPLIT FIRST: "the product queue is empty" must be an EFFECT of this arm, never a
# LEFTOVER from the fixture before it (review cycle 3, P1). Every fixture below reuses "$T/wo", and the
# all-harness fixture above leaves product.txt EMPTY — so `product=0` was satisfied without the arm
# writing anything at all. Measured: DELETING BOTH queued writes from the TRUNCATED, the BUDGET-SKIPPED,
# the NOT-A-PRODUCT-REPO and the LISTING-FAILED arms left the suite fully green. Seeding a non-empty
# product queue plus a wrong harness queue makes both assertions satisfiable ONLY by the arm rewriting
# them.
stale() { printf '99\n' > "$T/wo/candidates.product.txt"; printf '99\n99\n' > "$T/wo/candidates.harness.txt"; rm -f "$T/wo/state/product-class"; }
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
OUTF="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 1)"
PRODF="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
HARNF="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" | sed 's/ $//')"
[ "$PRODF" = "0" ] && [ "$HARNF" = "12 34 56" ]
ck "P7 [RED→GREEN] a FAILED label listing classifies everything as HARNESS (product=$PRODF harness='$HARNF')" $?
case "$OUTF" in *"listing FAILED"*) W2=0 ;; *) W2=1 ;; esac
ck "P7 [RED→GREEN] ... and says the read failed rather than inventing a class (got '$OUTF')" $W2
case "$(pcwhy "$T/wo")" in LISTING-FAILED*) W2R=0 ;; *) W2R=1 ;; esac
ck "P7 [RED→GREEN] ... and records LISTING-FAILED as the reason (got '$(pcwhy "$T/wo")')" $W2R
# ⛔ A SATURATED WINDOW IS NOT A COMPLETE ONE (review cycle 2, P2). This listing is read for ABSENCE, so a
# harness row outside the window would be classified PRODUCT and take the floor slot — the polarity above,
# inverted. Driven through the seam the shipped `rest_list` actually sets.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
OUTS="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 1)"
PRODS="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
HARNS="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" | sed 's/ $//')"
[ "$PRODS" = "0" ] && [ "$HARNS" = "12 34 56" ]
ck "P7 [RED→GREEN] a TRUNCATED harness listing manufactures NO product work (product=$PRODS harness='$HARNS')" $?
case "$(pcwhy "$T/wo")" in LISTING-TRUNCATED*) W4=0 ;; *) W4=1 ;; esac
ck "P7 [RED→GREEN] ... and records LISTING-TRUNCATED, so the operator is told which cause it was (got '$(pcwhy "$T/wo")')" $W4
case "$OUTS" in *TRUNCATED*) W4O=0 ;; *) W4O=1 ;; esac
ck "P7 [RED→GREEN] ... and says so on the pass line too (got '$OUTS')" $W4O
# A spent budget is the third all-harness arm, and it records its own reason.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
OUTB="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 10 20)"
PB0="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
PBH0="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" 2>/dev/null | sed 's/ $//')"
[ "$PB0" = "0" ] && [ "$PBH0" = "12 34 56" ]
ck "P7 [RED→GREEN] a spent budget lists nothing and manufactures no product work (product=$PB0 harness='$PBH0')" $?
case "$(pcwhy "$T/wo")" in BUDGET-SKIPPED*) W5=0 ;; *) W5=1 ;; esac
ck "P7 [RED→GREEN] ... and records BUDGET-SKIPPED (got '$(pcwhy "$T/wo")')" $W5
# A repo outside PRODUCT_REPOS is all-harness by definition, and costs NO call at all.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
OUTR="$(wk "$T/wo" daniel-ospina/agent-infra daniel-ospina/tortoise 0 "12 56")"
PRODR="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
HARNR="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" 2>/dev/null | sed 's/ $//')"
[ "$PRODR" = "0" ] && [ "$HARNR" = "12 34 56" ]
ck "P7 [RED→GREEN] a repo OUTSIDE PRODUCT_REPOS is all-harness (product=$PRODR harness='$HARNR')" $?
case "$OUTR" in *"not in PRODUCT_REPOS"*) W3=0 ;; *) W3=1 ;; esac
ck "P7 [RED→GREEN] ... and names the knob that decides it (got '$OUTR')" $W3
case "$(pcwhy "$T/wo")" in NOT-A-PRODUCT-REPO*) W3R=0 ;; *) W3R=1 ;; esac
ck "P7 [RED→GREEN] ... and records NOT-A-PRODUCT-REPO, which the loop reports as N/A (got '$(pcwhy "$T/wo")')" $W3R
# ⛔ AN ELEMENT MATCH, NOT A SUBSTRING (review cycle 12, P2). README documents `*" $repo "*` and the whole
# point of the space padding is that `daniel-ospina/tortoise-fork` must NOT make `daniel-ospina/tortoise`
# product — a mutation to `*"$repo"*` left the suite fully green (126/0), because every fixture used one
# exact element. Both directions are driven: the longer unrelated element first, and the listed one second.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
# The repo must be a STRING PREFIX of the listed element for a substring match to differ: `x/tortoise`
# against `x/tortoise-fork`, not two different owners (which share no substring and pinned nothing).
OUTPF="$(wk "$T/wo" x/tortoise 'x/tortoise-fork' 0 "12 56")"
PRODPF="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PRODPF" = "0" ]
ck "P7 [RED→GREEN] a repo that merely PREFIXES a listed element is still all-harness (product=$PRODPF)" $?
case "$OUTPF" in *"not in PRODUCT_REPOS"*) W3P=0 ;; *) W3P=1 ;; esac
ck "P7 [RED→GREEN] ... and it is refused as not-in-PRODUCT_REPOS, not silently treated as product (got '$OUTPF')" $W3P
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
wk "$T/wo" x/tortoise 'x/other,x/tortoise' 0 "12 56" >/dev/null
PRODPS="$(tr '\n' ' ' < "$T/wo/candidates.product.txt" | sed 's/ $//')"
[ "$PRODPS" = "34" ]
ck "P7 [RED→GREEN] an element in the MIDDLE of the list still classifies (product='$PRODPS')" $?

echo
echo "── P8: the ORDER the loop READS is the floor's, and the wiring is pinned ─────────────"
# ⛔ THE WIRING IS THE PART THAT CAN GO INERT (cycle-1 review, P1). Reverting the loop's redirect to
# `done < "$O/candidates.txt"` — the floor then never applies AT ALL — left every assertion in this
# file green. Two pins: the choice is DRIVEN through the shipped `floor_choose_order`, and the redirect
# that consumes it is named.
mkdir -p "$T/o8"; printf '12\n34\n56\n' > "$T/o8/candidates.txt"; printf '34\n' > "$T/o8/candidates.product.txt"
CH="$(floor_choose_order "$T/o8" 1)"
[ "$CH" = "$T/o8/.order" ] && [ -s "$T/o8/.order" ]
ck "P8 [RED→GREEN] with a product candidate the loop is pointed at \$O/.order (got '$CH')" $?
GOT="$(tr '\n' ' ' < "$T/o8/.order" 2>/dev/null | sed 's/ $//')"
[ "$GOT" = "34 12 56" ]
ck "P8 [RED→GREEN] ... and that file IS the floor order, product first (got '$GOT')" $?
CH="$(floor_choose_order "$T/o8" 0)"
[ "$CH" = "$T/o8/candidates.txt" ] && [ ! -e "$T/o8/.order" ]
ck "P8 [RED→GREEN] floor=0 points at candidates.txt and REMOVES a stale .order (got '$CH')" $?
printf '12\n34\n56\n' > "$T/o8/candidates.txt"; : > "$T/o8/candidates.product.txt"
CH="$(floor_choose_order "$T/o8" 1)"
[ "$CH" = "$T/o8/candidates.txt" ]
ck "P8 [RED→GREEN] an EMPTY product queue degrades to candidates.txt (got '$CH')" $?
# ⛔ ANCHORED TO A CODE LINE, NOT TO ANYWHERE IN THE FILE (measured, cycle-1 follow-up): a bare
# `grep 'done < "$ORDER_FILE"'` also matched the COMMENT in orch-loop.sh that quotes this line, so a
# mutation reverting the redirect itself left the pin GREEN. A comment cannot satisfy `^[[:space:]]*done`.
grep -Eq '^[[:space:]]*done < "\$ORDER_FILE"[[:space:]]*$' "$LOOP"
ck "P8 [RED→GREEN] the dispatch loop READS \$ORDER_FILE (the line that makes the floor real)" $?
grep -q 'ORDER_FILE="$(floor_choose_order' "$LOOP"
ck "P8 [RED→GREEN] ... and \$ORDER_FILE comes from floor_choose_order, not from a bare literal" $?
# ⛔ AND THE CONSUMER VERIFIES THE PATH IT WAS HANDED (review cycle 33, P2). `floor_choose_order` returns a PATH;
# a redirect that failed in a way its own guard cannot see puts the SHELL'S DIAGNOSTIC into that expansion, so
# `done < "$ORDER_FILE"` opened nothing, the batch loop ran zero iterations, and the cycle logged an empty batch
# while issues were waiting. Deleting the one-line fallback left every other gate green (measured), so it is
# pinned by shape as well as by behaviour.
grep -Eq '^[[:space:]]*\[ -f "\$ORDER_FILE" \] \|\| ORDER_FILE="\$O/candidates\.txt"[[:space:]]*$' "$LOOP"
ck "P8 [RED→GREEN] the consumer falls back to candidates.txt when the path it was handed does not exist" $?
# ⛔ AND AN UNWRITABLE $O MUST NOT PUT A SHELL ERROR ON THE CONTROLLER'S STDERR (review cycle 30, P2). The
# `.order` write is a `>` redirect, and a REDIRECT failure is reported by the shell BEFORE the command runs, so
# `2>/dev/null` on the command cannot silence it: every cycle printed a raw `…/.order: Permission denied`.
# The behaviour was right (the fallback ran) — the noise was not. Both halves are driven: the guard exists, and
# an unwritable directory produces the fallback with NO shell error in the output.
grep -q '&& [ -w "$o" ]' "$FNS"
ck "P8 [RED→GREEN] floor_choose_order GUARDS the .order write on a writable \$O (a redirect failure cannot be silenced)" $?
# ⛔ AND THE FIXTURE GUARDS ON THE OBSERVABLE (review cycle 31, P1): on a ROOT box `chmod 500` does not remove
# root's write permission, so `[ -w "$o" ]` stays TRUE, `.order` IS written, and the assertion below would fail
# for an environment reason — the same trap this file fixed twice already. `[ ! -w ]` is the state the fixture
# needs; when the box cannot produce it, the arm is SKIPPED (counted separately, never as a pass).
mkdir -p "$T/o8r"; printf '12\n34\n' > "$T/o8r/candidates.txt"; printf '34\n' > "$T/o8r/candidates.product.txt"
chmod 500 "$T/o8r" 2>/dev/null || :
if [ ! -w "$T/o8r" ]; then
  OUT8R="$(floor_choose_order "$T/o8r" 1 2>&1)"
  chmod 700 "$T/o8r" 2>/dev/null || :
  case "$OUT8R" in *"Permission denied"*|*"not permitted"*|*"Read-only"*) R8=1 ;; *) R8=0 ;; esac
  ck "P8 [RED→GREEN] ... and an UNWRITABLE \$O prints no shell error (got '${OUT8R:0:120}')" $R8
  case "$OUT8R" in *"candidates.txt"*) R9=0 ;; *) R9=1 ;; esac
  ck "P8 [RED→GREEN] ... while still falling back to candidates.txt (got '${OUT8R:0:120}')" $R9
else
  chmod 700 "$T/o8r" 2>/dev/null || :
  ck "P8 (skipped) cannot make \$O unwritable on this box (running as root?) — no shell error" 0
  ck "P8 (skipped) ... — falls back to candidates.txt" 0
fi
# ⛔ A WRITABLE DIRECTORY IS NOT A WRITABLE TARGET (review cycle 31, P2): a restored/`cp -p`-ed state dir can hold
# a read-only `.order`, so the directory-only guard still let the shell print `Permission denied` every cycle.
mkdir -p "$T/o8t"; printf '12\n34\n' > "$T/o8t/candidates.txt"; printf '34\n' > "$T/o8t/candidates.product.txt"
printf '99\n' > "$T/o8t/.order"; chmod 400 "$T/o8t/.order"
if [ -w "$T/o8t" ] && [ ! -w "$T/o8t/.order" ]; then
  OUT8T="$(floor_choose_order "$T/o8t" 1 2>&1)"
  chmod 600 "$T/o8t/.order" 2>/dev/null || :
  case "$OUT8T" in *"Permission denied"*|*"not permitted"*) T8=1 ;; *) T8=0 ;; esac
  ck "P8 [RED→GREEN] ... and a READ-ONLY .order in a writable \$O prints no shell error (got '${OUT8T:0:120}')" $T8
  case "$OUT8T" in *"candidates.txt"*) T9=0 ;; *) T9=1 ;; esac
  ck "P8 [RED→GREEN] ... and falls back rather than trusting a target it cannot write" $T9
else
  chmod 600 "$T/o8t/.order" 2>/dev/null || :
  ck "P8 (skipped) cannot make .order read-only on this box (running as root?) — no shell error" 0
  ck "P8 (skipped) ... — falls back rather than trusting the target" 0
fi
# ⛔ "WRITABLE" IS NOT "REGULAR" (review cycle 34, P2): `[ -w ]` is TRUE for a directory, so a directory occupying
# `$O/.order` passed both guards and the shell then printed `Is a directory` — the raw-diagnostic class the guards
# exist to remove, through the one path shape they could not see. Driven on a real directory, so this arm runs on
# every platform (no chmod involved).
mkdir -p "$T/o8d/.order"; printf '12\n34\n56\n' > "$T/o8d/candidates.txt"; printf '34\n' > "$T/o8d/candidates.product.txt"
OUT8D="$(floor_choose_order "$T/o8d" 1 2>&1)"
case "$OUT8D" in *"Is a directory"*|*"Permission denied"*|*"Not a directory"*) D8=1 ;; *) D8=0 ;; esac
ck "P8 [RED→GREEN] a DIRECTORY at \$O/.order puts no shell error in the controller's stderr (got '${OUT8D:0:120}')" $D8
case "$OUT8D" in *"candidates.txt"*) D9=0 ;; *) D9=1 ;; esac
ck "P8 [RED→GREEN] ... and the fallback still returns candidates.txt" $D9
# ⛔ A REMOVAL THAT CANNOT SUCCEED IS NOT A REMOVAL (review cycle 31, P2): `rm -f` in an unwritable `$O` fails
# SILENTLY, so the stale `.order` from an earlier pass survived while this function returned `candidates.txt` —
# the "authoritative-looking stale file" the comment promises cannot happen. An unlink needs a writable DIRECTORY,
# but the FILE is usually still writable, so the fallback empties it. The state is a stale order + unwritable dir.
mkdir -p "$T/o8u"; printf '12\n34\n' > "$T/o8u/candidates.txt"
: > "$T/o8u/candidates.product.txt"; printf '99\n98\n' > "$T/o8u/.order"
chmod 500 "$T/o8u" 2>/dev/null || :
if [ ! -w "$T/o8u" ]; then
  chmod 600 "$T/o8u/.order" 2>/dev/null || :
  OUT8U="$(floor_choose_order "$T/o8u" 1 2>&1)"
  chmod 700 "$T/o8u" 2>/dev/null || :
  case "$OUT8U" in *"candidates.txt"*) U8=0 ;; *) U8=1 ;; esac
  ck "P8 [RED→GREEN] ... an unwritable \$O still returns candidates.txt (got '${OUT8U:0:100}')" $U8
  # the promise is that NO reader finds a stale order; gone or empty both keep it
  if [ -s "$T/o8u/.order" ]; then U9=1; else U9=0; fi
  ck "P8 [RED→GREEN] ... and the stale .order is gone or EMPTIED, never left authoritative (size=$(wc -c < "$T/o8u/.order" 2>/dev/null || echo gone))" $U9
else
  chmod 700 "$T/o8u" 2>/dev/null || :
  ck "P8 (skipped) cannot make \$O unwritable on this box (running as root?) — returns candidates.txt" 0
  ck "P8 (skipped) ... — the stale .order is emptied" 0
fi

echo
# ⛔ A DEGRADE ARM THAT COULD NOT WRITE MUST NOT REPORT A SPLIT (review cycle 7, P1). The four
# "everything is harness" arms wrote with `|| :` and then printed a count — so a failed write both lied
# and, worse, could leave a STALE NON-EMPTY product queue while the record said the class was absent, and
# the loop then satisfied the floor from a file this pass had just declared it could not classify.
DGF="$T/degrade.sh"
{ sed -n '/^wpq_writable() {/,/^}/p' "$REFRESH"; sed -n '/^wpq_fallback() {/,/^}/p' "$REFRESH"; sed -n '/^write_record() {/,/^}/p' "$REFRESH"; sed -n '/^record_state_note() {/,/^}/p' "$REFRESH"; sed -n '/^wpq_degrade() {/,/^}/p' "$REFRESH"; } > "$DGF"
[ -s "$DGF" ] && grep -q 'product-class' "$DGF"
ck "P8b (setup) the degrade helper extracts from the shipped refresh" $?
rundg() { # <O> -> what the helper printed
  ( o="$1"; . "$DGF" || exit 1
    wpq_degrade "$o" 'NOT-A-PRODUCT-REPO vendor/x is not in PRODUCT_REPOS (y), so every candidate is harness' \
      '[refresh] split: every candidate is HARNESS — vendor/x is not in PRODUCT_REPOS (y)' ) 2>&1
}
mkdir -p "$T/dg1/state"; printf '12\n34\n' > "$T/dg1/candidates.txt"
DGO="$(rundg "$T/dg1")"
[ ! -s "$T/dg1/candidates.product.txt" ] && [ "$(wc -l < "$T/dg1/candidates.harness.txt" | tr -d ' ')" = "2" ]
ck "P8b [RED→GREEN] a degrade arm EMPTIES the product queue and gives the harness queue the backlog" $?
case "$DGO" in *"could not be written"*) G1=1 ;; *) G1=0 ;; esac
ck "P8b [RED→GREEN] ... and says nothing about a write that did not fail — got '$DGO'" $G1
case "$DGO" in *"product 0 harness"*) G2=1 ;; *) G2=0 ;; esac
ck "P8b [RED→GREEN] ... and claims NO count it did not measure (got '$DGO')" $G2
# The dangerous case: the product queue CANNOT be emptied (a directory occupies the path), so a stale
# non-empty queue survives unless the write is verified — the record must say so rather than assert a
# class the disk denies.
mkdir -p "$T/dg2/state" "$T/dg2/candidates.product.txt"; printf '12\n34\n' > "$T/dg2/candidates.txt"
DGO2="$(rundg "$T/dg2")"
case "$(head -1 "$T/dg2/state/product-class")" in *"could not be written"*) G3=0 ;; *) G3=1 ;; esac
ck "P8b [RED→GREEN] a degrade arm whose write FAILED records that the queues may still hold a previous split (got '$(head -1 "$T/dg2/state/product-class")')" $G3
case "$DGO2" in *"could not be written"*) G4=0 ;; *) G4=1 ;; esac
ck "P8b [RED→GREEN] ... and says it on the operator line too (got '$DGO2')" $G4
# The other half of the same claim: the HARNESS queue must hold the BACKLOG. A pre-existing, unwritable
# harness queue keeps the old rows; asserting "every candidate is treated as HARNESS" over it is false on
# disk even though both paths are regular files (measured: checking `-f` alone left this green).
mkdir -p "$T/dg3/state"; printf '12\n34\n56\n' > "$T/dg3/candidates.txt"
printf '99\n99\n' > "$T/dg3/candidates.harness.txt"; chmod 400 "$T/dg3/candidates.harness.txt"
if [ ! -w "$T/dg3/candidates.harness.txt" ]; then
  DGO3="$(rundg "$T/dg3")"
  chmod 600 "$T/dg3/candidates.harness.txt" 2>/dev/null || :
  case "$DGO3" in *"could not be written"*) G5=0 ;; *) G5=1 ;; esac
  ck "P8b [RED→GREEN] a degrade arm whose HARNESS queue still holds the old rows does not claim the backlog was classified (got '$DGO3')" $G5
else
  chmod 600 "$T/dg3/candidates.harness.txt" 2>/dev/null || :
  ck "P8b (skipped) cannot make the harness queue read-only on this box (running as root?)" 0
fi
# ⛔ AND A LINE COUNT IS NOT A CONTENT CHECK (review cycle 12, P2). The check was `wc -l` while its comment
# claimed content, so a stale harness queue certifies itself whenever its stale row COUNT matches the
# backlog's — the routine case right after one issue is dispatched and one queued. Here the stale file has
# the SAME number of lines and different rows, with the write refused: the arm must not claim the backlog.
mkdir -p "$T/dg4/state"; printf '12\n34\n' > "$T/dg4/candidates.txt"
printf '12\n99\n' > "$T/dg4/candidates.harness.txt"; chmod 400 "$T/dg4/candidates.harness.txt"
if [ ! -w "$T/dg4/candidates.harness.txt" ]; then
  DGO4="$(rundg "$T/dg4")"
  chmod 600 "$T/dg4/candidates.harness.txt" 2>/dev/null || :
  case "$DGO4" in *"could not be written"*) G6=0 ;; *) G6=1 ;; esac
  ck "P8b [RED→GREEN] a stale harness queue with the SAME line count is still a failed write (got '$DGO4')" $G6
  H4="$(tr '\n' ' ' < "$T/dg4/candidates.harness.txt" | sed 's/ $//')"
  [ "$H4" = "12 99" ]
  ck "P8b (setup) the fixture really left mismatched rows on disk (harness='$H4')" $?
else
  chmod 600 "$T/dg4/candidates.harness.txt" 2>/dev/null || :
  ck "P8b (skipped) cannot make the harness queue read-only on this box (running as root?) — failed write" 0
  ck "P8b (skipped) ... — mismatched rows on disk" 0
fi
# ⛔ "WHAT IS ON DISK" IS A MEASUREMENT (review cycle 14, P2). On a FULL DISK `printf … > file` truncates BEFORE
# it fails, so the record is left EMPTY — not "the previous pass's record" and not "whatever stood before this
# run", both of which these messages used to assert. A permission failure fails WITHOUT truncating and does
# leave the old content. All three states are driven, the empty one through a real size limit rather than a
# mock, because a fixture that only ever chmods cannot reach it.
mkdir -p "$T/dg5/state"; printf '12\n34\n' > "$T/dg5/candidates.txt"
printf 'OK product=0 harness=3\n' > "$T/dg5/state/product-class"
DGF5="$T/degrade5.sh"
{ sed -n '/^wpq_writable() {/,/^}/p' "$REFRESH"; sed -n '/^wpq_fallback() {/,/^}/p' "$REFRESH"; sed -n '/^write_record() {/,/^}/p' "$REFRESH"; sed -n '/^record_state_note() {/,/^}/p' "$REFRESH"; sed -n '/^wpq_degrade() {/,/^}/p' "$REFRESH"; } > "$DGF5"
DGO5="$( ( o="$T/dg5"; . "$DGF5" || exit 1
  # Model a write that FAILS AFTER TRUNCATING — what a full disk does to a `>` redirect. ⚠️ `ulimit -f 0` is NOT a
  # full disk (measured, review cycle 31): the redirected write fails, returns 1, leaves the target at 0 bytes and
  # LEAKS the redirected text to the stdout of the caller, whereas a real ENOSPC fails the OPEN with "No space left on
  # device". The state this fixture grades (the record emptied) is the same either way; the analogy is not.
  trap '' XFSZ 2>/dev/null || :
  ulimit -f 0 2>/dev/null || :
  wpq_degrade "$o" 'NOT-A-PRODUCT-REPO x is not in PRODUCT_REPOS (y), so every candidate is harness' 'msg' ) 2>&1 )"
SZ5="$(wc -c < "$T/dg5/state/product-class" 2>/dev/null | tr -d ' ')"
case "$DGO5" in *"is EMPTY"*) E1=0 ;; *) E1=1 ;; esac
ck "P8b [RED→GREEN] a TRUNCATED record is reported as EMPTY, not as a record that is still there (size=${SZ5:-?}, got '${DGO5:0:120}')" $E1
case "$DGO5" in *"the record already on disk"*) E2=1 ;; *) E2=0 ;; esac
ck "P8b [RED→GREEN] ... and it does not claim a standing record is there (it is 0 bytes)" $E2
# ⛔ A `2>/dev/null` ON THE COMMAND DOES NOT SILENCE A REDIRECT (review cycle 33, P2). Every record/queue write in
# the writer is a `>` redirect: if the target or its directory cannot be written the SHELL reports it before the
# command runs, so the pass log carried a raw `…/state/product-class: Permission denied` on every pass. The
# fixtures below drive the writer against an unwritable `state/` and an unwritable `$O` and require NO shell
# diagnostic on the operator's output — the same claim the `.order` fixtures make for the loop.
for _wp in "state" "root" "dir"; do
  if [ "$_wp" = "dir" ]; then
    # a DIRECTORY on the record path: `[ -w ]` is true for one, so only a `-f` probe keeps the shell quiet
    mkdir -p "$T/wp_$_wp/state/product-class"; printf '12\n34\n' > "$T/wp_$_wp/candidates.txt"
    _wpw="$T/wp_$_wp/state/product-class"
  else
    mkdir -p "$T/wp_$_wp/state"; printf '12\n34\n' > "$T/wp_$_wp/candidates.txt"
    # the guard names the path the fixture RESTRICTED (state/ is the writable child of an unwritable $O)
    if [ "$_wp" = "state" ]; then chmod 500 "$T/wp_$_wp/state"; else chmod 500 "$T/wp_$_wp"; fi
    if [ "$_wp" = "state" ]; then _wpw="$T/wp_$_wp/state"; else _wpw="$T/wp_$_wp"; fi
  fi
  # the guard names the state the fixture CREATED: a permission denial for the chmod cases, a directory for `dir`
  # (a directory is `-w`, so a `[ ! -w ]` guard would SKIP the very case it exists to drive — measured).
  if [ "$_wp" = "dir" ]; then _wpg=1; [ -d "$_wpw" ] && _wpg=0; else _wpg=1; [ ! -w "$_wpw" ] && _wpg=0; fi
  if [ "$_wpg" = "0" ]; then
    WPO="$(wk "$T/wp_$_wp" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12" 2>&1)"
    case "$WPO" in
      *"Permission denied"*|*"Read-only"*|*"not permitted"*|*"Is a directory"*|*"Not a directory"*) WPW=1 ;;
      *) WPW=0 ;;
    esac
    chmod 700 "$T/wp_$_wp" "$T/wp_$_wp/state" 2>/dev/null || :
    ck "P8b [RED→GREEN] an unwritable $_wp puts NO shell error in the pass log (got '$(printf '%s' "$WPO" | head -c 110)')" $WPW
  else
    chmod 700 "$T/wp_$_wp" "$T/wp_$_wp/state" 2>/dev/null || :
    ck "P8b (skipped) cannot make $_wp unwritable on this box (running as root?) — no shell error in the log" 0
  fi
done
# The permission case: the file is read-only, so the write fails BEFORE truncating and the old line survives.
mkdir -p "$T/dg6/state"; printf '12\n34\n' > "$T/dg6/candidates.txt"
printf 'OK product=0 harness=3\n' > "$T/dg6/state/product-class"; chmod 400 "$T/dg6/state/product-class"
if [ ! -w "$T/dg6/state/product-class" ]; then
  DGO6="$(rundg "$T/dg6")"
  chmod 600 "$T/dg6/state/product-class" 2>/dev/null || :
  case "$DGO6" in *"the record already on disk"*"OK product=0 harness=3"*) E3=0 ;; *) E3=1 ;; esac
  ck "P8b [RED→GREEN] an UNTRUNCATED failed write names the record that really is on disk, with its line (got '${DGO6:0:130}')" $E3
else
  chmod 600 "$T/dg6/state/product-class" 2>/dev/null || :
  ck "P8b (skipped) cannot make the record read-only on this box (running as root?)" 0
fi


echo "── P10: the split's budget gate and its write are CHECKED, not assumed ─────────────────────"
# ⛔ THE GATE MUST RESERVE THE LISTING'S OWN COST, IN THE LISTING'S OWN UNIT (this lane's cycle-2/3
# review, P2). `--limit 500` pages at 100 RAW rows per request, so the read costs ceil(500/100) = 5 core
# REQUESTS — not 5 * CORE_PER_CANDIDATE. Two boundaries are driven, because "reserve something" and
# "reserve the right thing" are different claims: at reserve+pages the split runs, one request short of
# it the split is refused, and the record names the number it needed.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
OUTH1="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 24 20)"
PH1="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PH1" = "0" ]
ck "P10 [RED→GREEN] reserve+pages-1 (24 vs 20+5) is NOT affordable for the 5-request listing (product=$PH1)" $?
case "$(pcwhy "$T/wo")" in BUDGET-SKIPPED*needs=25*"5 paged request"*) H1=0 ;; *) H1=1 ;; esac
ck "P10 [RED→GREEN] ... and the reason names the number it NEEDED (reserve+5 pages), not just what was left (got '$(pcwhy "$T/wo")')" $H1
# The same pass with exactly the full cost available DOES split — a gate that refuses everything is not a gate.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTH2="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 25 20)"
PH2="$(tr '\n' ' ' < "$T/wo/candidates.product.txt" | sed 's/ $//')"
[ "$PH2" = "34" ]
ck "P10 [RED→GREEN] a pass with exactly reserve+5 pages splits normally (product='$PH2')" $?
# ⛔ AND THE BOUND IS IN REQUESTS, NOT IN CANDIDATES (review cycle 3, P2). The shipped form multiplied
# the PER-CANDIDATE estimate by the page count (5 * 6 = 30), so an unrelated pre-flight knob silently
# decided whether this listing could run: with CORE_PER_CANDIDATE=1000 a pass holding exactly the
# listing's cost was refused, and the reason line still said "+ 5 paged requests".
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTH3="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 25 20 1000)"
PH3="$(tr '\n' ' ' < "$T/wo/candidates.product.txt" | sed 's/ $//')"
[ "$PH3" = "34" ]
ck "P10 [RED→GREEN] the bound does not scale with CORE_PER_CANDIDATE (a per-candidate estimate): product='$PH3'" $?
# …and the same knob set to 0 cannot collapse the bound to the bare reserve, which would let the listing
# spend the reserve it is supposed to preserve.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
stale
OUTH4="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 20 20 0)"
PH4="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PH4" = "0" ]
ck "P10 [RED→GREEN] CORE_PER_CANDIDATE=0 cannot make a pass AT the reserve affordable (product=$PH4)" $?
# ⛔ A SPLIT THAT COULD NOT BE WRITTEN IS NOT A SPLIT (this lane's cycle-2 review, P2). The counts were
# printed from `wc -l` on files the write may never have created, so a full disk printed
# `OK product=0 harness=0` — and a `0` product count is exactly what the loop reports as a MEASURED
# absence. Forced hermetically: a DIRECTORY occupies the product-queue path, so the `mv` cannot land.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
rm -f "$T/wo/candidates.product.txt" "$T/wo/candidates.harness.txt" "$T/wo/state/product-class"
mkdir -p "$T/wo/candidates.product.txt"
OUTX="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56")"
HARNX="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" 2>/dev/null | sed 's/ $//')"
[ "$HARNX" = "12 34 56" ]
ck "P10 [RED→GREEN] a split whose write FAILED leaves the whole backlog as HARNESS ('$HARNX')" $?
case "$(pcwhy "$T/wo")" in WRITE-FAILED*) X1=0 ;; *) X1=1 ;; esac
ck "P10 [RED→GREEN] ... and records WRITE-FAILED rather than an OK it did not measure (got '$(pcwhy "$T/wo")')" $X1
case "$OUTX" in *"split: product"*) X2=1 ;; *) X2=0 ;; esac
ck "P10 [RED→GREEN] ... and prints NO counts it did not measure (got '$OUTX')" $X2
case "$OUTX" in *"split FAILED to write"*) X3=0 ;; *) X3=1 ;; esac
ck "P10 [RED→GREEN] ... and says the write failed on the pass line (got '$OUTX')" $X3
rm -rf "$T/wo/candidates.product.txt" 2>/dev/null || :
# ⛔ THE OTHER HALF OF THAT GUARD (review cycle 3, P3). The fixture above forces the PRODUCT side, and the
# harness side was therefore never driven: `mv f <dir>` exits 0 by moving the temp INSIDE a directory
# occupying the queue path, and `wc -l < <dir>` then prints `0` at rc 1 — so the exit-code gate certified
# a harness queue that was never written and REPORTED the zero it did not measure. Gated on the artefact
# (`-f`), the same failure now takes the WRITE-FAILED arm and claims no count.
# A FRESH sandbox on purpose: the product-path directory above is MOVED INTO by the failing `mv`, so it
# cannot be rmdir'd, and its leftover state made the first version of this fixture report WRITE-FAILED for
# the WRONG reason (measured: the mutation below stayed green until this used its own directory).
mkdir -p "$T/wy/state"; printf '12\n34\n56\n' > "$T/wy/candidates.txt"
mkdir -p "$T/wy/candidates.harness.txt"
OUTY="$(wk "$T/wy" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56")"
case "$(pcwhy "$T/wy")" in WRITE-FAILED*) Y1=0 ;; *) Y1=1 ;; esac
ck "P10 [RED→GREEN] a directory on the HARNESS queue path is a WRITE FAILURE, not an OK (got '$(pcwhy "$T/wy")')" $Y1
case "$OUTY" in *"split: product"*) Y2=1 ;; *) Y2=0 ;; esac
ck "P10 [RED→GREEN] ... and it prints no counts it did not measure (got '$OUTY')" $Y2
# ⛔ `-f` IS NOT "EVERY CANDIDATE IS HARNESS" (review cycle 20, P2). When the fallback `cp` FAILS but the
# PREVIOUS pass's harness queue is still on disk, `-f` stays true and that stale split survives — so the arm
# published it as the class under the words "every candidate is treated as HARNESS", with no disclosure.
# Only a CONTENT comparison can tell the two apart (that is why `wpq_degrade` uses `cmp -s`).
# Forced hermetically by making BOTH the split's `mv` and the fallback's `cp` fail without touching their
# targets — the shape of a disk that is full for this pass. (A chmod cannot model it: `mv`/`cp` overwrite a
# 0400 file happily when the DIRECTORY is writable — measured.)
# ⛔ Stubbing the commands inside the substitution needs care: an APOSTROPHE in a comment there starts a
# quote, because `$(` sits inside double quotes and that comment is not treated as one (measured).
wkboth_fail() { # <O> — the shipped writer, with both queue writes failing
  local o="$1"
  (
    O="$o"; CORE_NOW=0; CORE_RESERVE=""; REST_WINDOW_FILLED=0
    rest_list() { printf '%s\n' 12 56; }
    # shellcheck source=/dev/null
    . "$WFNS" || exit 1
    mv() { return 1; }
    cp() { return 1; }
    write_product_queues "$o" daniel-ospina/tortoise daniel-ospina/tortoise
  ) 2>&1
}
mkdir -p "$T/wz/state"; printf '12\n34\n56\n' > "$T/wz/candidates.txt"
printf '99\n98\n' > "$T/wz/candidates.harness.txt"; : > "$T/wz/candidates.product.txt"
OUTZ9="$(wkboth_fail "$T/wz")"
HARNZ="$(tr '\n' ' ' < "$T/wz/candidates.harness.txt" | sed 's/ $//')"
case "$OUTZ9" in *"fallback did NOT take"*) W1=0 ;; *) W1=1 ;; esac
ck "P10 [RED→GREEN] a fallback that failed onto a STALE harness queue says so instead of claiming every candidate is harness (got '${OUTZ9:0:200}')" $W1
case "$OUTZ9" in *"2 lines on disk"*) W2=0 ;; *) W2=1 ;; esac
ck "P10 [RED→GREEN] ... and reads the FILE to say what it actually holds (2 lines), not an assumed state (harness on disk='$HARNZ')" $W2
case "$(pcwhy "$T/wz")" in WRITE-FAILED*"fallback did NOT take"*) W3=0 ;; *) W3=1 ;; esac
ck "P10 [RED→GREEN] ... and the RECORD carries the same disclosure (got '$(pcwhy "$T/wz")')" $W3

echo
echo "── P9: the UNMET block is EXECUTED, and it leaves the batch intact ────────────────────────"
# ⛔ NO SUITE RAN THIS BLOCK (this lane's cycle-2 review, P1; re-verified after the merge: a
# `: > "$O/.batch"; K=0` placed as the UNKNOWN arm's first statement leaves the suite fully GREEN).
# Every other assertion about the unmet path is a text pin, and a text pin cannot see what the arm
# DOES. Here the SHIPPED reporting block is extracted and run against fixtures, with the real floor
# helpers and a stub `queue_state_token`; the property asserted is the one the issue states — an
# unmet floor LOGS, and the work already selected is still dispatched.
BLOCK="$T/unmetblock.sh"
awk '/^    # ⛔ AN UNMET FLOOR LOGS AND DEGRADES/ {f=1} f {print} f && /^    fi$/ {exit}' "$LOOP" > "$BLOCK.raw"
grep -q 'product-floor' "$BLOCK.raw"
ck "P9 (setup) the unmet reporting block extracts from the shipped loop" $?
{
  sed -n '/^pc_state_note() {/,/^}/p' "$LOOP"
  sed -n '/^floor_norm() {/,/^}/p' "$LOOP"
  sed -n '/^floor_order() {/,/^}/p' "$LOOP"
  sed -n '/^floor_choose_order() {/,/^}/p' "$LOOP"
  printf 'queue_state_token() { printf "READ(3)"; }\n'
  cat "$BLOCK.raw"
} > "$BLOCK"
runblock() { # <O> [batch rows] [floor] — the state the block inherits from the dispatch loop
  (
    # `BATCH` and `K` differ on purpose (review cycle 10, P2): every fixture used BATCH=2; K=2, so the
    # count line's `product=$PB/$K` and a mutation to `$BATCH` were indistinguishable — a printed count
    # could stop equalling the count computed with nothing noticing. BATCH=3 with a two-row batch keeps
    # them apart: the batch holds 2, the cap is 3, and only K may appear as the denominator.
    O="$1"; LOG="$1/log"; BATCH=3; K="${4:-2}"
    # ⛔ `BL` IS DELIBERATELY NOT SET HERE (review cycle 19, P0). The shipped block referenced `$BL`, which
    # the loop assigns LATER in the same iteration — under `set -u` that EXITED the controller on the first
    # cycle of any box that dispatched nothing, and this fixture hid it by supplying the variable the shipped
    # code should have derived (the listed false-green class, exactly). The block now measures its own
    # backlog, and the fixture runs it under `set -u` so any other unbound read is fatal here too.
    : > "$LOG"
    # The daemon computes FLOOR_N just before this block; an EMPTY value reads 0 and the whole block
    # is skipped, which looked exactly like "the arm says nothing" when this was first wired.
    FLOOR_N="$(floor_norm "${3:-1}" 2)"
    # `%b`, not `%s`: an overridden batch carries its own newlines, which `%s` prints literally.
    # `${2-…}`, not `${2:-…}`: with the colon an EMPTY batch argument is replaced by the default, so the idle
    # cycle (K=0) could not be driven through this fixture at all — which is why the cycle-18 defect was
    # invisible here.
    printf '%b' "${2-42\n43\n}" > "$O/.batch"
    set -u
    . "$BLOCK" || exit 1
    # The block reports through `>> "$LOG"`, so the fixture reads the log it wrote, not stdout.
    printf 'BATCH=[%s] K=[%s] LOG=[%s]\n' "$(tr '\n' ' ' < "$O/.batch" | sed 's/ $//')" "$K" \
      "$(tr '\n' ' ' < "$LOG" 2>/dev/null | sed 's/ *$//')"
  ) 2>&1
}
# (a) NO product queue at all, and nothing recorded about the class: the UNKNOWN arm.
mkdir -p "$T/o9a/state"; printf '42\n43\n' > "$T/o9a/candidates.txt"
OUTA="$(runblock "$T/o9a")"
case "$OUTA" in *"BATCH=[42 43]"*"K=[2]"*) A1=0 ;; *) A1=1 ;; esac
ck "P9 [RED→GREEN] NO product queue: the batch and K SURVIVE (a floor is not a gate) — got '$OUTA'" $A1
case "$OUTA" in *"product class UNKNOWN"*"queue=READ(3)"*) A2=0 ;; *) A2=1 ;; esac
ck "P9 [RED→GREEN] ... and the arm says UNKNOWN with the queue token (got '$OUTA')" $A2
# (b) a product queue holding something not in this batch: the MEASURED arm.
mkdir -p "$T/o9b/state"; printf '42\n43\n' > "$T/o9b/candidates.txt"; printf '99\n' > "$T/o9b/candidates.product.txt"
printf 'OK product=1 harness=0\n' > "$T/o9b/state/product-class"
OUTB="$(runblock "$T/o9b")"
case "$OUTB" in *"BATCH=[42 43]"*"K=[2]"*) A3=0 ;; *) A3=1 ;; esac
ck "P9 [RED→GREEN] a product queue with NO dispatchable match: the batch still dispatches — got '$OUTB'" $A3
case "$OUTB" in *"no dispatchable product candidate"*"queue=READ(3)"*) A4=0 ;; *) A4=1 ;; esac
ck "P9 [RED→GREEN] ... and THAT arm reports the MEASURED absence (got '$OUTB')" $A4
# (c) a repo the refresh RECORDED as not a product repo: N/A, and still dispatched.
mkdir -p "$T/o9c/state"; printf '42\n43\n' > "$T/o9c/candidates.txt"
printf 'NOT-A-PRODUCT-REPO vendor/harness is not in PRODUCT_REPOS (daniel-ospina/tortoise)\n' > "$T/o9c/state/product-class"
OUTC="$(runblock "$T/o9c")"
case "$OUTC" in *"BATCH=[42 43]"*"K=[2]"*) A5=0 ;; *) A5=1 ;; esac
ck "P9 [RED→GREEN] an N/A class does not touch the batch either — got '$OUTC'" $A5
case "$OUTC" in *"product-floor N/A"*) A6=0 ;; *) A6=1 ;; esac
ck "P9 [RED→GREEN] ... and it reports N/A rather than an unmet floor (got '$OUTC')" $A6
# (d) a class the refresh could not read: UNKNOWN, repeating the RECORDED reason instead of re-asking.
mkdir -p "$T/o9d/state"; printf '42\n43\n' > "$T/o9d/candidates.txt"
printf 'BUDGET-SKIPPED the pass had no core budget left\n' > "$T/o9d/state/product-class"
OUTD="$(runblock "$T/o9d")"
case "$OUTD" in *"reason=BUDGET-SKIPPED"*) A7=0 ;; *) A7=1 ;; esac
ck "P9 [RED→GREEN] the UNKNOWN arm repeats the RECORDED reason instead of asking (got '$OUTD')" $A7
# The count line is printed only where a product queue EXISTS, so drive it with one: a product candidate
# that is not in the batch (PB=0), a two-row batch, and BATCH=3 — the denominator must be 2.
mkdir -p "$T/o9d/state"; printf '42\n43\n' > "$T/o9d/candidates.txt"; printf '99\n' > "$T/o9d/candidates.product.txt"
printf 'OK product=1 harness=2\n' > "$T/o9d/state/product-class"
OUTD="$(runblock "$T/o9d")"
case "$OUTD" in *"product=0/2 in this batch (floor=1)"*) A1b=0 ;; *) A1b=1 ;; esac
ck "P9 [RED→GREEN] the count line's denominator is the BATCH SIZE (2), never the BATCH cap (3) — got '$OUTD'" $A1b
# ⛔ AND THE POSITIVE LINE MUST NOT CLAIM A PRODUCT-LED BATCH THAT IS NOT ONE (review cycle 11, P2). A
# product QUEUE naming only issues that are no longer in the backlog still produces a `.order` (it equals
# the backlog), and the old message said "ordered from <queue> first" for a batch with ZERO product entries
# in it — contradicting the `product=0/2` and `product-floor unmet … no dispatchable product candidate`
# lines printed immediately below it. The arm is extracted from the shipped loop (the unmet block below is
# a different region) and driven on both sides of the claim.
PLED="$T/positive.sh"
awk '/^    FLOOR_N="\$\(floor_norm/ {f=1} f {print} f && /^    fi$/ {exit}' "$LOOP" > "$PLED.raw"
grep -q 'product-floor=' "$PLED.raw"
ck "P9 (setup) the positive floor line extracts from the shipped loop" $?
{
  sed -n '/^pc_state_note() {/,/^}/p' "$LOOP"
  sed -n '/^floor_norm() {/,/^}/p' "$LOOP"
  sed -n '/^floor_order() {/,/^}/p' "$LOOP"
  sed -n '/^floor_choose_order() {/,/^}/p' "$LOOP"
  cat "$PLED.raw"
} > "$PLED"
runled() { ( O="$1"; LOG="$1/log"; BATCH=2; : > "$LOG"; . "$PLED" || exit 1
  printf 'LOG=[%s]\n' "$(tr '\n' ' ' < "$LOG" 2>/dev/null | sed 's/ *$//')" ) 2>&1; }
mkdir -p "$T/o9z"; printf '12\n56\n' > "$T/o9z/candidates.txt"; printf '34\n' > "$T/o9z/candidates.product.txt"
OUTZ="$(runled "$T/o9z")"
case "$OUTZ" in *"NO product entry led it"*) Z1=0 ;; *) Z1=1 ;; esac
ck "P9 [RED→GREEN] a queue whose entries left the backlog reports NO product entry led the batch — got '$OUTZ'" $Z1
case "$OUTZ" in *"ordered from"*) Z2=1 ;; *) Z2=0 ;; esac
ck "P9 [RED→GREEN] ... and it does not claim the batch was ordered from the product queue" $Z2
mkdir -p "$T/o9y"; printf '12\n34\n' > "$T/o9y/candidates.txt"; printf '34\n' > "$T/o9y/candidates.product.txt"
OUTY2="$(runled "$T/o9y")"
case "$OUTY2" in *"1 product entry of"*) Z3=0 ;; *) Z3=1 ;; esac
ck "P9 [RED→GREEN] a product entry that IS dispatchable is reported as leading, with its count — got '$OUTY2'" $Z3
# The COUNT itself, not just its presence: two product entries leading one batch must print 2 (a constant
# "1 product entry" message satisfied the one-entry fixture above, measured 125/0).
mkdir -p "$T/o9x"; printf '12\n34\n56\n' > "$T/o9x/candidates.txt"; printf '34\n56\n' > "$T/o9x/candidates.product.txt"
OUTX="$( ( O="$T/o9x"; LOG="$T/o9x/log"; BATCH=2; PRODUCT_FLOOR=2; : > "$LOG"; . "$PLED" ) 2>&1; tr '\n' ' ' < "$T/o9x/log")"
case "$OUTX" in *"2 product entries of"*) Z4=0 ;; *) Z4=1 ;; esac
ck "P9 [RED→GREEN] the leading count is MEASURED — two product entries print 2, not a constant (got '$OUTX')" $Z4
# ⛔ THE CAP GETS ITS OWN LABEL (review cycle 20, P2). This line runs BEFORE the batch exists, so it can only
# print the cap — but it printed it as `batch=$BATCH`, while every other floor line in the same cycle prints
# `batch=` for the COUNT (`product=$PB/$K in this batch`). With BATCH=2 and ONE issue dispatched, one cycle's
# log then read `product-floor=1 of batch=2` beside `product=1/1 in this batch`. Pin the distinct word.
case "$OUTY2" in *"of batch-cap=2"*) Z5=0 ;; *) Z5=1 ;; esac
ck "P9 [RED→GREEN] the led line labels the cap 'batch-cap=' (distinct from the count 'batch=') — got '$OUTY2'" $Z5
case "$OUTY2" in *"of batch=2"*) Z6=1 ;; *) Z6=0 ;; esac
ck "P9 [RED→GREEN] ... and does not label the CAP with the word the count uses" $Z6
# ⛔ AN IDLE CYCLE OWES NOTHING (review cycle 18, P1). The unmet arms were keyed on file emptiness, so with an
# EMPTY batch (`K=0`: drained backlog, or every candidate skipped) the block reported `product-floor unmet` —
# the words reserved for a share that was owed and missed — and the SAME cycle reported `N/A` on a non-product
# repo and NOTHING when the product queue was non-empty. All three shapes are driven here and must agree: no
# "unmet", one distinct line, carrying the queue token.
mkdir -p "$T/o9i/state"; : > "$T/o9i/candidates.txt"; : > "$T/o9i/candidates.product.txt"
printf 'OK product=0 harness=0\n' > "$T/o9i/state/product-class"
OUTI="$(runblock "$T/o9i" "" 1 0)"
case "$OUTI" in *"product-floor not evaluated"*"batch is EMPTY"*"queue=READ(3)"*) I1=0 ;; *) I1=1 ;; esac
ck "P9 [RED→GREEN] an EMPTY batch reports 'not evaluated — no slot was owed', with the token (got '${OUTI:0:130}')" $I1
case "$OUTI" in *"product-floor unmet"*) I2=1 ;; *) I2=0 ;; esac
ck "P9 [RED→GREEN] ... and it never says 'unmet' on a cycle where nothing was dispatched" $I2
rm -f "$T/o9i/state/product-class"
OUTI2="$(runblock "$T/o9i" "" 1 0)"
case "$OUTI2" in *"product-floor not evaluated"*) I3=0 ;; *) I3=1 ;; esac
ck "P9 [RED→GREEN] ... the same verdict with NO record at all (not the UNKNOWN/unmet arm) (got '${OUTI2:0:130}')" $I3
# ⛔ AN `OK` PREFIX IS NOT A CLAIM ABOUT *THESE* FILES (review cycle 21, P2). The writer returns success after
# a FAILED record write on purpose, leaving the PREVIOUS pass's `OK product=N …` standing beside queues it no
# longer describes — and the OK arm repeated it as "the split RAN and found none", publishing a stale count
# as a measurement. Both sides are driven: an `OK product=0` record beside an empty queue IS the measured
# empty, while an `OK product=2` record beside an empty queue is a record that describes different files.
# A DISPATCHED batch (K=2) with an EMPTY product queue: that is the arm under test, so the idle-cycle arm
# (which would answer the question above) must not pre-empt it.
mkdir -p "$T/o9s/state"; printf '42\n43\n' > "$T/o9s/candidates.txt"; : > "$T/o9s/candidates.product.txt"
printf 'OK product=0 harness=0\n' > "$T/o9s/state/product-class"
: > "$T/o9s/candidates.harness.txt"
OUTS1="$(runblock "$T/o9s" '42\n43\n' 1 2)"
case "$OUTS1" in *"the split RAN and found none"*"OK product=0"*) S1=0 ;; *) S1=1 ;; esac
ck "P9 [RED→GREEN] an OK product=0 record beside an empty queue IS the measured empty (got '${OUTS1:0:150}')" $S1
printf 'OK product=2 harness=1\n' > "$T/o9s/state/product-class"
OUTS2="$(runblock "$T/o9s" '42\n43\n' 1 2)"
# the pattern follows the MESSAGE's order: the record is quoted BEFORE the verdict word.
case "$OUTS2" in *"OK product=2"*"does NOT describe these queues"*) S2=0 ;; *) S2=1 ;; esac
ck "P9 [RED→GREEN] an OK record whose OWN count (2) disagrees with the empty queue is NOT published as a measurement (got '${OUTS2:0:150}')" $S2
case "$OUTS2" in *"the split RAN and found none"*) S3=1 ;; *) S3=0 ;; esac
ck "P9 [RED→GREEN] ... and it does not claim the split found none, which the record contradicts" $S3
# ⛔ AND THE OTHER NUMBER ON THE SAME RECORD (review cycle 22, P2). Cycle 21 cross-checked only `product=`, so a
# stale `OK product=0 harness=5` beside a 3-line harness queue was still published as this pass's measurement —
# printing `harness=5` while the file holds 3, which is a printed count that does not equal the count on disk.
# Both directions are driven: the honest record still reports the measurement, the stale one does not.
mkdir -p "$T/o9t/state"; printf '42\n43\n' > "$T/o9t/candidates.txt"
: > "$T/o9t/candidates.product.txt"; printf '44\n45\n46\n' > "$T/o9t/candidates.harness.txt"
printf 'OK product=0 harness=3\n' > "$T/o9t/state/product-class"
OUTT1="$(runblock "$T/o9t" '42\n43\n' 1 2)"
case "$OUTT1" in *"the split RAN and found none"*"harness=3"*) T1=0 ;; *) T1=1 ;; esac
ck "P9 [RED→GREEN] a record whose product= AND harness= both match the disk IS the measured empty (got '${OUTT1:0:150}')" $T1
printf 'OK product=0 harness=5\n' > "$T/o9t/state/product-class"
OUTT2="$(runblock "$T/o9t" '42\n43\n' 1 2)"
# the pattern follows the MESSAGE's order: the file's counts are named first, then the record quoted.
case "$OUTT2" in *"harness=3, but the record"*"harness=5"*"does NOT describe these queues"*) T2=0 ;; *) T2=1 ;; esac
ck "P9 [RED→GREEN] a stale harness=5 beside a 3-line queue is NOT published — the message names BOTH counts (got '${OUTT2:0:170}')" $T2
case "$OUTT2" in *"the split RAN and found none"*) T3=1 ;; *) T3=0 ;; esac
ck "P9 [RED→GREEN] ... and it does not repeat the stale harness count as a measurement" $T3
# and an absent harness queue reads as 0 with NO shell error in the log (a `< file` redirect failure is not
# silenced by `2>/dev/null` on the same command — measured).
mkdir -p "$T/o9u/state"; printf '42\n43\n' > "$T/o9u/candidates.txt"
: > "$T/o9u/candidates.product.txt"; rm -f "$T/o9u/candidates.harness.txt"
printf 'OK product=0 harness=0\n' > "$T/o9u/state/product-class"
OUTU="$(runblock "$T/o9u" '42\n43\n' 1 2)"
case "$OUTU" in *"No such file or directory"*) U1=1 ;; *) U1=0 ;; esac
ck "P9 [RED→GREEN] an ABSENT harness queue reads as 0 and puts no shell error in the log (got '${OUTU:0:150}')" $U1
# ⛔ …AND THE SAME GUARD ON THE PRODUCT QUEUE (review cycle 23, P2). The fix above touched two reads and only
# the harness one was pinned, so deleting the guard from the product read left the suite fully green while an
# absent product queue put `No such file or directory` in the log — the same failure, one field over.
mkdir -p "$T/o9v/state"; printf '42\n43\n' > "$T/o9v/candidates.txt"
rm -f "$T/o9v/candidates.product.txt"; printf '44\n45\n' > "$T/o9v/candidates.harness.txt"
printf 'OK product=0 harness=2\n' > "$T/o9v/state/product-class"
OUTV="$(runblock "$T/o9v" '42\n43\n' 1 2)"
case "$OUTV" in *"No such file or directory"*) V1=1 ;; *) V1=0 ;; esac
ck "P9 [RED→GREEN] an ABSENT PRODUCT queue reads as 0 and puts no shell error in the log (got '${OUTV:0:150}')" $V1
case "$OUTV" in *"product-floor unmet"*) V2=0 ;; *) V2=1 ;; esac
ck "P9 [RED→GREEN] ... and the unmet arm still reports, with the counts it read" $V2
printf 'NOT-A-PRODUCT-REPO vendor/x is not in PRODUCT_REPOS\n' > "$T/o9i/state/product-class"
OUTI3="$(runblock "$T/o9i" "" 1 0)"
# ⛔ THE SAME VERDICT, NOT "EITHER ARM" (review cycle 19, P2). This accepted `not evaluated OR N/A`, and N/A is
# precisely the arm the idle-cycle change exists to exclude — so the one assertion claiming the three idle
# shapes agree stayed green when the fix was reverted.
case "$OUTI3" in *"product-floor not evaluated"*) I4=0 ;; *) I4=1 ;; esac
ck "P9 [RED→GREEN] ... and a non-product repo on an idle cycle gives the SAME verdict, not N/A (got '${OUTI3:0:130}')" $I4
# ⛔ A VERDICT ARM MUST CHECK THE FILES (review cycle 31, P2). `NOT-A-PRODUCT-REPO` was the only record arm chosen
# on the PREFIX alone — and it prints "NOT a finding about product work", the masking shape the whole line exists
# to remove, wearing the N/A arm. Its claim is structural: the harness queue IS the backlog. Both sides driven.
mkdir -p "$T/o9v2/state"; printf '42\n43\n' > "$T/o9v2/candidates.txt"
: > "$T/o9v2/candidates.product.txt"; printf '42\n43\n' > "$T/o9v2/candidates.harness.txt"
printf 'NOT-A-PRODUCT-REPO vendor/x is not in PRODUCT_REPOS\n' > "$T/o9v2/state/product-class"
OUTV2="$(runblock "$T/o9v2")"
case "$OUTV2" in *"NOT an unmet floor"*) V3=0 ;; *) V3=1 ;; esac
ck "P9 [RED→GREEN] a NOT-A-PRODUCT-REPO record whose harness queue IS the backlog is the routine N/A (got '${OUTV2:0:150}')" $V3
printf '99\n' > "$T/o9v2/candidates.harness.txt"
OUTV3="$(runblock "$T/o9v2")"
case "$OUTV3" in *"does NOT describe these files"*"treat the class as unread"*) V4=0 ;; *) V4=1 ;; esac
ck "P9 [RED→GREEN] ... but one whose harness queue does NOT hold the backlog is not published as a verdict (got '${OUTV3:0:170}')" $V4
case "$OUTV3" in *"NOT an unmet floor"*) V5=1 ;; *) V5=0 ;; esac
ck "P9 [RED→GREEN] ... and it does not say 'NOT a finding about product work' about files it did not check" $V5
# ⛔ AND THE CHECK IS SUBSET, NOT EQUALITY (review cycle 32, P2). Equality is FALSE in the ROUTINE state: the loop
# prunes dispatched ids from `candidates.txt` on every dispatch while the harness queue is only rewritten by a
# refresh pass, so ONE dispatch after the writer ran the two files differ by design — and the arm published "treat
# the class as unread" about a perfectly ordinary non-product box. The honest claim is that nothing still
# dispatchable was classified product: the backlog is a SUBSET of the harness queue.
printf '42\n43\n' > "$T/o9v3_harness_src.txt"
mkdir -p "$T/o9v3/state"; printf '43\n' > "$T/o9v3/candidates.txt"
: > "$T/o9v3/candidates.product.txt"; printf '42\n43\n' > "$T/o9v3/candidates.harness.txt"
printf 'NOT-A-PRODUCT-REPO vendor/x is not in PRODUCT_REPOS\n' > "$T/o9v3/state/product-class"
OUTV4="$(runblock "$T/o9v3")"
case "$OUTV4" in *"NOT an unmet floor"*"NOT a finding about product work"*) V6=0 ;; *) V6=1 ;; esac
ck "P9 [RED→GREEN] the POST-PRUNE state (backlog ⊂ harness queue) is the routine N/A, not 'treat the class as unread' (got '${OUTV4:0:170}')" $V6
# ... and a backlog id that is MISSING from the harness queue is still a disagreement
printf '43\n77\n' > "$T/o9v3/candidates.txt"
OUTV5="$(runblock "$T/o9v3")"
case "$OUTV5" in *"does NOT describe these files"*) V7=0 ;; *) V7=1 ;; esac
ck "P9 [RED→GREEN] ... while a backlog id absent from the harness queue is still published as a disagreement (got '${OUTV5:0:170}')" $V7
# ⛔ AND IT IS AN EXACT MATCH (review cycle 37, P2). `grep -qx` here is the FOURTH membership test in this change —
# the other three are pinned as exact (P3 `floor_order`, the P9 `PB` walk, the P9 led count) and this one, which
# gates the "NOT a finding about product work" verdict, was not: loosening it to `grep -q` makes a backlog id `4`
# count as present because the harness queue holds `42`, so the masking verdict is published over a real
# disagreement. Driven with exactly that pair.
mkdir -p "$T/o9v4/state"; printf '4\n' > "$T/o9v4/candidates.txt"
: > "$T/o9v4/candidates.product.txt"; printf '42\n' > "$T/o9v4/candidates.harness.txt"
printf 'NOT-A-PRODUCT-REPO vendor/x is not in PRODUCT_REPOS\n' > "$T/o9v4/state/product-class"
OUTV6="$(runblock "$T/o9v4")"
case "$OUTV6" in *"does NOT describe these files"*) V8=0 ;; *) V8=1 ;; esac
ck "P9 [RED→GREEN] a backlog id that is merely a PREFIX of a harness-queue id (4 vs 42) is still a disagreement (got '${OUTV6:0:170}')" $V8
case "$OUTV6" in *"NOT a finding about product work"*) V9=1 ;; *) V9=0 ;; esac
ck "P9 [RED→GREEN] ... and the masking verdict is not published over it" $V9
# ⛔ THE NUMBER ON THAT LINE IS GRADED TOO (review cycle 20, P2). Every idle fixture above uses an EMPTY
# `candidates.txt`, so only `backlog=0` was ever exercised and the value could name the wrong file or be an
# unset default with all 146 assertions still green. A DRAINED box is the case that matters (the backlog is
# empty because everything was dispatched, not because nothing exists), and a box where the backlog is NOT
# empty while nothing was dispatched (everything skipped) is a different statement — so the number must be
# the FILE's, measured here, with the batch still empty.
mkdir -p "$T/o9n/state"; printf '12\n34\n56\n' > "$T/o9n/candidates.txt"
: > "$T/o9n/candidates.product.txt"; printf 'OK product=0 harness=0\n' > "$T/o9n/state/product-class"
OUTN="$(runblock "$T/o9n" "" 1 0)"
case "$OUTN" in *"batch is EMPTY (backlog=3, nothing"*) N1=0 ;; *) N1=1 ;; esac
ck "P9 [RED→GREEN] the idle line's backlog=N is the count in candidates.txt (3), not a default or another file (got '${OUTN:0:150}')" $N1
# and it must be the BACKLOG's number, not the product queue's (which is empty here: 0).
case "$OUTN" in *"backlog=0"*) N2=1 ;; *) N2=0 ;; esac
ck "P9 [RED→GREEN] ... and it is not the PRODUCT queue's count (0) under the backlog's label" $N2
# ⛔ THE LED COUNT IS WINDOWED BY THE FLOOR, AND NOTHING PINNED THE WINDOW (review cycle 17, P2). The count
# walks `head -"$FLOOR_N" .order`, and the only fixture above uses PRODUCT_FLOOR=2 with exactly two product
# entries — so `head -N` and `cat` are indistinguishable there, and counting a product entry from the TAIL as
# having "led" (contradicting the `floor=` in the same sentence) left the suite green. Here ONE slot exists and
# TWO product entries are dispatchable: exactly one may be counted.
mkdir -p "$T/o9w"; printf '12\n34\n56\n' > "$T/o9w/candidates.txt"; printf '34\n56\n' > "$T/o9w/candidates.product.txt"
OUTW2="$( ( O="$T/o9w"; LOG="$T/o9w/log"; BATCH=2; PRODUCT_FLOOR=1; : > "$LOG"; . "$PLED" ) 2>&1; tr '\n' ' ' < "$T/o9w/log")"
case "$OUTW2" in *"1 product entry of"*) Z8=0 ;; *) Z8=1 ;; esac
ck "P9 [RED→GREEN] with ONE floor slot and TWO product candidates, the led count is 1, not the whole tail (got '$OUTW2')" $Z8
# ⛔ …AND THE WINDOW MUST BE THE FLOOR, NOT THE BATCH (review cycle 34, P2). In the fixture above BOTH product
# entries are the first two lines of `.order` anyway, so `head -"$FLOOR_N"` and `head -"$BATCH"` — which is 2 —
# produce the same count and the mutation survived. Here the product entries LEAD and the batch window is
# WIDER than the floor, so the two windows differ: floor=1, batch=2, `.order` = "34 56 12" — the led count is 1.
mkdir -p "$T/o9w3"; printf '56\n12\n34\n' > "$T/o9w3/candidates.txt"; printf '34\n56\n' > "$T/o9w3/candidates.product.txt"
OUTW3="$( ( O="$T/o9w3"; LOG="$T/o9w3/log"; BATCH=2; PRODUCT_FLOOR=1; : > "$LOG"; . "$PLED" ) 2>&1; tr '\n' ' ' < "$T/o9w3/log")"
case "$OUTW3" in *"1 product entry of"*) Z9=0 ;; *) Z9=1 ;; esac
ck "P9 [RED→GREEN] the led count is windowed by the FLOOR (1), not by BATCH (2), when they disagree (got '$OUTW3')" $Z9
case "$OUTW3" in *"2 product entries of"*) Z10=1 ;; *) Z10=0 ;; esac
ck "P9 [RED→GREEN] ... and it does not report the wider BATCH window's count" $Z10
# ⛔ AND THE PRODUCT COUNT IS DE-DUPLICATED (review cycle 38, P2). `awk '!seen[$0]++'` guards the `PB` walk; removing it
# makes the count one per QUEUE LINE, so a duplicated row prints `product=2/1` — a count larger than its own
# denominator — and can push `PB >= floor`, suppressing the `unmet` line for a batch that dispatched one product
# issue. Reachable only through a queue that is not derived from the deduped backlog, which is why the deliverable
# is the pin rather than a behaviour change.
mkdir -p "$T/o9d2/state"; printf '34\n12\n' > "$T/o9d2/candidates.txt"
printf '34\n34\n' > "$T/o9d2/candidates.product.txt"; printf 'OK product=2 harness=1\n' > "$T/o9d2/state/product-class"
OUTD2="$(runblock "$T/o9d2" '34\n12\n' 2 2)"
case "$OUTD2" in *"product=1/2 in this batch"*) D21=0 ;; *) D21=1 ;; esac
ck "P9 [RED→GREEN] a DUPLICATED product-queue row counts ONCE (product=1/2, not 2/2 or 2/1) (got '$(printf '%s' "$OUTD2" | grep -o 'product=[0-9]*/[0-9]* in this batch' | head -1)')" $D21
case "$OUTD2" in *"product-floor unmet"*) D22=0 ;; *) D22=1 ;; esac
ck "P9 [RED→GREEN] ... and the unmet line is still reported for a floor of 2 with one product candidate" $D22
# ⛔ AND THE LINE'S OWN GATE IS PINNED (review cycle 37, P2). It is printed only when the floor produced `.order`
# THIS pass; the gate was unpinned, so removing it makes the line assert ".order exists" in states where `.order` is
# NOT on disk — the floor being OFF, or `floor_choose_order` having just removed the file. (The conjunction that also
# read `[ "$FLOOR_N" -gt 0 ]` was DELETED this cycle: `floor_choose_order` returns `.order` only on the branch that
# requires floor>0, so that half could never change the answer and no fixture could drive it.)
mkdir -p "$T/o9w4"; printf '34\n12\n' > "$T/o9w4/candidates.txt"; printf '34\n' > "$T/o9w4/candidates.product.txt"
OUTW4="$( ( O="$T/o9w4"; LOG="$T/o9w4/log"; BATCH=2; PRODUCT_FLOOR=0; : > "$LOG"; . "$PLED" ) 2>&1; tr '\n' ' ' < "$T/o9w4/log")"
case "$OUTW4" in *"product-floor="*) W14=1 ;; *) W14=0 ;; esac
ck "P9 [RED→GREEN] with the floor OFF (PRODUCT_FLOOR=0) the positive line is not printed at all (got '${OUTW4:0:120}')" $W14
# the second gate: a floor ABOVE ZERO whose product queue is EMPTY makes floor_choose_order return candidates.txt
# (and REMOVE `.order`), so the line must stay silent about a file the floor did not produce. Driven this way, not
# through an unwritable `$O`: that fixture could not capture its own log either (measured — the log write failed
# with the directory), so the assertion would have been vacuous.
mkdir -p "$T/o9w5"; printf '34\n12\n' > "$T/o9w5/candidates.txt"; : > "$T/o9w5/candidates.product.txt"
OUTW5="$( ( O="$T/o9w5"; LOG="$T/o9w5/log"; BATCH=2; PRODUCT_FLOOR=1; : > "$LOG"; . "$PLED" ) 2>&1; tr '\n' ' ' < "$T/o9w5/log")"
[ ! -e "$T/o9w5/.order" ]
ck "P9 (setup) the fixture's floor produced NO .order, so this is the state the gate excludes" $?
case "$OUTW5" in *".order exists"*) W15=1 ;; *) W15=0 ;; esac
ck "P9 [RED→GREEN] with floor>0 but no \$O/.order produced, the line does not report on it (got '${OUTW5:0:120}')" $W15
# ⛔ AND THE LED COUNT IS AN EXACT MATCH (review cycle 36, P2). `grep -qx` here is the third place in this change
# where a membership test must not be a prefix test: the ORDER LINE is the pattern, so a product queue holding
# `134` would be counted as having led an order containing `34` — a false "product led it" in the one line that
# reports whether the floor did anything. The walk's `PB` half has had this pin since cycle 7; the ordering half
# and this counter did not.
mkdir -p "$T/pc1" "$T/pc1/state"; printf '34\n12\n' > "$T/pc1/candidates.txt"; printf '134\n' > "$T/pc1/candidates.product.txt"
printf 'OK product=1 harness=2\n' > "$T/pc1/state/product-class"
OUTPC1="$(runled "$T/pc1")"
case "$OUTPC1" in *"NO product entry led it"*) P11=0 ;; *) P11=1 ;; esac
ck "P9 [RED→GREEN] a product queue entry that CONTAINS the order's number (134 vs 34) did not lead it (got '$(printf '%s' "$OUTPC1" | grep -o 'led the order\|NO product entry led it' | head -1)')" $P11
# ⛔ A NON-EMPTY QUEUE MUST NOT SILENCE THE RECORD (review cycle 16, P2). The recorded class was read only
# when the product queue was EMPTY, so a NON-EMPTY queue skipped it — including a STALE one, which is exactly
# what `wpq_degrade` discloses and what a dispatched-then-pruned issue leaves behind. The floor then reported
# itself MET from a queue the intake had just declared untrustworthy, and a `PENDING` record ("no split has
# run") was presented as a measurement. Both sides are driven: a `PENDING` record with a non-empty queue must
# be disowned, and an `OK` record with the same queue must NOT be (the count is the measurement then).
mkdir -p "$T/o9p/state"; printf '42\n43\n' > "$T/o9p/candidates.txt"; printf '42\n' > "$T/o9p/candidates.product.txt"
printf 'PENDING this pass has started but has not recorded a product class yet\n' > "$T/o9p/state/product-class"
OUTP="$(runblock "$T/o9p")"
case "$OUTP" in *"NOT a trustworthy floor measurement"*"PENDING"*) Z5=0 ;; *) Z5=1 ;; esac
ck "P9 [RED→GREEN] a PENDING record with a NON-EMPTY product queue is disowned, not reported as a met floor (got '${OUTP:0:150}')" $Z5
# the record's counts must MATCH the files for it to be a measurement (cycle 25): one product line on disk,
# so the harness file must hold the other line of the backlog.
printf 'OK product=1 harness=1\n' > "$T/o9p/state/product-class"
printf '43\n' > "$T/o9p/candidates.harness.txt"
OUTP2="$(runblock "$T/o9p")"
case "$OUTP2" in *"NOT a trustworthy floor measurement"*) Z6=1 ;; *) Z6=0 ;; esac
ck "P9 [RED→GREEN] ... and an OK record with the same queue is NOT disowned (the count IS a measurement) (got '${OUTP2:0:150}')" $Z6
# ⛔ AND THE MET-FLOOR ARM CROSS-CHECKS TOO (review cycle 25, P1). Cycles 21/22 taught the EMPTY-queue arm to
# compare the record's counts with the files; this arm — the one that reports the floor as MET — still took the
# record on its prefix alone, so a stale `OK product=0 harness=1` beside a queue that now holds a product
# candidate was published as a trustworthy measurement with NO disclosure.
mkdir -p "$T/o9q/state"; printf '42\n43\n' > "$T/o9q/candidates.txt"
printf '42\n' > "$T/o9q/candidates.product.txt"; printf '43\n' > "$T/o9q/candidates.harness.txt"
printf 'OK product=0 harness=1\n' > "$T/o9q/state/product-class"
OUTQ="$(runblock "$T/o9q")"
# patterns follow the MESSAGE's order: files' counts, then the record, then the verdict.
case "$OUTQ" in *"product=1 harness=1"*"OK product=0"*"does NOT describe these files"*) Q1=0 ;; *) Q1=1 ;; esac
ck "P9 [RED→GREEN] a record contradicting a NON-EMPTY product queue is disowned, with both counts named (got '${OUTQ:0:180}')" $Q1
case "$OUTQ" in *"product=1/2 in this batch (floor=1)"*) Q2=0 ;; *) Q2=1 ;; esac
ck "P9 [RED→GREEN] ... and the count line is still printed (the disclosure is beside it, not instead of it)" $Q2
printf 'OK product=1 harness=1\n' > "$T/o9q/state/product-class"
OUTQ2="$(runblock "$T/o9q")"
case "$OUTQ2" in *"NOT a trustworthy floor measurement"*) Q3=1 ;; *) Q3=0 ;; esac
ck "P9 [RED→GREEN] ... while the MATCHING record is not disowned — the cross-check is not a blanket warning" $Q3
# ⛔ AND THE CROSS-CHECK COMPARES THE FILES, NOT THE COMPUTED COUNT (review cycle 26, P2; the premise corrected
# in cycle 27). The `$PB` swap kept the suite green because NO fixture asserted SILENCE in the state where the
# two differ: `o9d` above does have `PB`=0 beside a 1-line product file, but its record's `harness=` (2) already
# disagreed with a MISSING harness file (0), so it printed the disclosure for that unrelated reason and could
# not discriminate the product half. The routine state — product queue names an issue no longer in the batch,
# record matching the FILES — reaches here with no harness mismatch, and the swap prints a FALSE "NOT a
# trustworthy floor measurement" in it. Driven on exactly that state, asserting SILENCE.
mkdir -p "$T/o9r/state"; printf '42\n43\n' > "$T/o9r/candidates.txt"
printf '99\n' > "$T/o9r/candidates.product.txt"; printf '42\n43\n' > "$T/o9r/candidates.harness.txt"
printf 'OK product=1 harness=2\n' > "$T/o9r/state/product-class"
OUTR="$(runblock "$T/o9r")"
case "$OUTR" in *"product=0/2 in this batch"*) R1=0 ;; *) R1=1 ;; esac
ck "P9 (setup) the product queue names only issues OUTSIDE the batch, so PB=0 while the file holds 1" $R1
case "$OUTR" in *"NOT a trustworthy floor measurement"*) R2=1 ;; *) R2=0 ;; esac
ck "P9 [RED→GREEN] ... and a record that MATCHES the FILES is not disowned for disagreeing with PB (got '${OUTR:0:170}')" $R2
# ⛔ AND THE HARNESS HALF IS DRIVEN (review cycle 26, P2). Deleting it from the comparison left 169/0: a stale
# `harness=` beside a product count that happens to match was published as a measurement. `OK product=1
# harness=9` beside a 2-line harness queue is exactly that state.
mkdir -p "$T/o9r2/state"; printf '42\n43\n' > "$T/o9r2/candidates.txt"
printf '42\n' > "$T/o9r2/candidates.product.txt"; printf '43\n44\n' > "$T/o9r2/candidates.harness.txt"
printf 'OK product=1 harness=9\n' > "$T/o9r2/state/product-class"
OUTR2="$(runblock "$T/o9r2")"
case "$OUTR2" in *"product=1 harness=2"*"harness=9"*"does NOT describe these files"*) R3=0 ;; *) R3=1 ;; esac
ck "P9 [RED→GREEN] a stale harness= is caught even when product= matches — both counts are cross-checked (got '${OUTR2:0:180}')" $R3
# ⛔ THE RECORD'S STATE IS A MEASUREMENT TOO (review cycle 28, P2). Both floor arms printed
# `[UNRECORDED: no record at all]` whenever `head -1` was empty — which is ALSO what an EMPTY record (a failed
# write truncates it) and an UNREADABLE one yield, sending the operator to look for a refresh pass that never ran
# when the real cause was a failed WRITE. Three disk states, three different sentences, all driven on the MET-
# floor arm (a non-empty product queue, so the `*)` arm runs).
mk_o9x() { mkdir -p "$T/$1/state"; printf '42\n43\n' > "$T/$1/candidates.txt"
  printf '42\n' > "$T/$1/candidates.product.txt"; printf '43\n' > "$T/$1/candidates.harness.txt"; }
mk_o9x o9x1
OUTX1="$(runblock "$T/o9x1")"
case "$OUTX1" in *"UNRECORDED: no record at all"*) X1b=0 ;; *) X1b=1 ;; esac
ck "P9 [RED→GREEN] an ABSENT record says no record exists (got '${OUTX1:0:150}')" $X1b
mk_o9x o9x2; : > "$T/o9x2/state/product-class"
OUTX2="$(runblock "$T/o9x2")"
case "$OUTX2" in *"EMPTY"*"failed write truncates it"*) X2b=0 ;; *) X2b=1 ;; esac
ck "P9 [RED→GREEN] an EMPTY record says it is EMPTY (a failed write truncates it) — not that no record exists (got '${OUTX2:0:170}')" $X2b
case "$OUTX2" in *"no record at all"*) X3b=1 ;; *) X3b=0 ;; esac
ck "P9 [RED→GREEN] ... and stops sending the operator after a refresh pass that DID run" $X3b
# ⛔ THE GUARD TESTS THE OBSERVABLE, NOT CHMOD'S EXIT STATUS (review cycle 29, P2): as root, `chmod 000`
# SUCCEEDS while the file stays readable, so the skip arm below can never fire for the case it names and a root
# box (the Linux cells) gets a hard FAIL instead of a skip. `[ ! -r ]` is the state this fixture needs.
if mk_o9x o9x3 && printf 'OK product=1 harness=1\n' > "$T/o9x3/state/product-class" \
   && chmod 000 "$T/o9x3/state/product-class" 2>/dev/null && [ ! -r "$T/o9x3/state/product-class" ]; then
  OUTX3="$(runblock "$T/o9x3")"
  chmod 600 "$T/o9x3/state/product-class" 2>/dev/null || :
  case "$OUTX3" in *"UNREADABLE"*) X4b=0 ;; *) X4b=1 ;; esac
  ck "P9 [RED→GREEN] an UNREADABLE record says UNREADABLE, not 'no record at all' (got '${OUTX3:0:160}')" $X4b
else
  chmod 600 "$T/o9x3/state/product-class" 2>/dev/null || :
  ck "P9 (skipped) cannot make the record unreadable on this box (running as root?)" 0
fi
# ⛔ AND THE WRITER SIDE OF THE SAME CLAIM (review cycle 29, P2). `record_state_note`'s clauses tell the operator
# what the floor WILL print; they promised "UNRECORDED" for an EMPTY record — false since the loop learned to
# say EMPTY — and had no UNREADABLE arm at all, so an unreadable record was described as "the record already on
# disk (\"\")". Driven on the same three states.
# ⛔ AND THEY ARE NOT NESTED INSIDE THE ROOT-SENSITIVE GUARD (review cycle 30, P1). The absent/empty assertions
# were inside the `if` above, so on a root box they never executed at all — including this commit's only pin for
# the EMPTY arm — and the suite exited 0 with a silently smaller total. Only the UNREADABLE arm needs the guard.
rsn() { ( O="$1"; . "$WFNS" >/dev/null 2>&1; record_state_note "$O" ) 2>&1; }
mkdir -p "$T/o9y1/state"
case "$(rsn "$T/o9y1")" in *"NO record at all"*"report UNRECORDED"*) Y1b=0 ;; *) Y1b=1 ;; esac
ck "P12 [RED→GREEN] an ABSENT record: the writer says the floor will report UNRECORDED (got '$(rsn "$T/o9y1")')" $Y1b
mkdir -p "$T/o9y2/state"; : > "$T/o9y2/state/product-class"
case "$(rsn "$T/o9y2")" in *"is EMPTY"*"report EMPTY"*) Y2b=0 ;; *) Y2b=1 ;; esac
ck "P12 [RED→GREEN] an EMPTY record: the writer promises EMPTY (what the loop actually prints), not UNRECORDED (got '$(rsn "$T/o9y2")')" $Y2b
# the loop's predicate, not a byte count (review cycle 30, P2): a record holding only whitespace is EMPTY to the
# floor, so it must not be quoted back to the operator as "the record already on disk".
mkdir -p "$T/o9y4/state"; printf '   \n' > "$T/o9y4/state/product-class"
case "$(rsn "$T/o9y4")" in *"is EMPTY"*"whitespace-only record counts as empty"*) Y4b=0 ;; *) Y4b=1 ;; esac
ck "P12 [RED→GREEN] a WHITESPACE-ONLY record is EMPTY on both sides, not 'already on disk' (got '$(rsn "$T/o9y4")')" $Y4b
# ⛔ AND THE LOOP SIDE IS DRIVEN TOO (review cycle 36, P2). Only the writer half of that claim was ever exercised, so
# `case "${l//[[:space:]]/}"` could be loosened to `case "$l"` — which makes the floor quote a BLANK reason= line
# instead of reporting EMPTY — and every assertion stayed green. The cause must also be the one that applies: a
# whitespace-only record was NOT truncated, so the loop may not say a failed write truncated it.
mkdir -p "$T/ws1/state"; printf '   \n' > "$T/ws1/state/product-class"
printf '12\n34\n' > "$T/ws1/candidates.txt"; : > "$T/ws1/candidates.product.txt"
OUTWS1="$(runblock "$T/ws1")"
case "$OUTWS1" in *"has only whitespace on its FIRST LINE"*) W11=0 ;; *) W11=1 ;; esac
ck "P12 [RED→GREEN] a WHITESPACE-ONLY record is EMPTY on the LOOP side, with the cause that applies (got '$(printf '%s' "$OUTWS1" | grep -o 'EMPTY: [^;]*' | head -1)')" $W11
case "$OUTWS1" in *"holds nothing (a failed write truncates it)"*) W12=1 ;; *) W12=0 ;; esac
ck "P12 [RED→GREEN] ... and it does not blame a truncated write for a write that SUCCEEDED" $W12
mkdir -p "$T/ws2/state"; : > "$T/ws2/state/product-class"
printf '12\n34\n' > "$T/ws2/candidates.txt"; : > "$T/ws2/candidates.product.txt"
OUTWS2="$(runblock "$T/ws2")"
case "$OUTWS2" in *"holds nothing (a failed write truncates it)"*) W13=0 ;; *) W13=1 ;; esac
ck "P12 [RED→GREEN] ... while a ZERO-BYTE record keeps the truncation sentence (both causes are named)" $W13
# ⛔ AND THE SENTENCE DESCRIBES WHAT WAS READ (review cycle 38, P2). The predicate tests `head -1`, so for the
# file this suite already builds at P12 (a blank first line with content BELOW) "holds only whitespace" and "the
# write wrote a blank line" are both false about the disk. The floor reads the first line, so it must say so — and
# must disclose that the rest of the file is not empty, because that is what an operator will see when they look.
mkdir -p "$T/ws3/state"; printf '\nOK product=1 harness=1\n' > "$T/ws3/state/product-class"
printf '12\n34\n' > "$T/ws3/candidates.txt"; : > "$T/ws3/candidates.product.txt"
OUTWS3="$(runblock "$T/ws3")"
case "$OUTWS3" in *"only whitespace on its FIRST LINE"*"carries content on the later lines"*) W16=0 ;; *) W16=1 ;; esac
ck "P12 [RED→GREEN] a blank FIRST LINE with content below is described as the first line plus the lines it ignores (got '$(printf '%s' "$OUTWS3" | grep -o 'EMPTY:[^;]*' | head -1)')" $W16
case "$OUTWS3" in *"holds only whitespace"*) W17=1 ;; *) W17=0 ;; esac
ck "P12 [RED→GREEN] ... and it does not claim the whole FILE holds only whitespace" $W17
case "$(rsn "$T/ws3")" in *"carries content on later lines"*) W18=0 ;; *) W18=1 ;; esac
ck "P12 [RED→GREEN] ... and the writer side discloses the same thing (got '$(rsn "$T/ws3")')" $W18
# ⛔ AND "CONTENT" MEANS CONTENT, NOT LINES (review cycle 39, P2). The disclosure above was selected by a LINE COUNT,
# so a record whose later lines are ALSO whitespace was described as "carries content on the later lines" — false in
# exactly the way this message exists to avoid. The test strips whitespace from lines 2..$ before answering, and the
# state is driven on both sides.
mkdir -p "$T/ws4/state"; printf '   \n   \n' > "$T/ws4/state/product-class"
printf '12\n34\n' > "$T/ws4/candidates.txt"; : > "$T/ws4/candidates.product.txt"
OUTWS4="$(runblock "$T/ws4")"
case "$OUTWS4" in *"carries content on the later lines"*) W19=1 ;; *) W19=0 ;; esac
ck "P12 [RED→GREEN] a record whose later lines are ALSO whitespace is not said to carry content (got '$(printf '%s' "$OUTWS4" | grep -o 'EMPTY:[^;]*' | head -1)')" $W19
case "$OUTWS4" in *"only whitespace on its FIRST LINE"*) W20=0 ;; *) W20=1 ;; esac
ck "P12 [RED→GREEN] ... while it is still reported as EMPTY on the first line" $W20
case "$(rsn "$T/ws4")" in *"carries content on later lines"*) W21=1 ;; *) W21=0 ;; esac
ck "P12 [RED→GREEN] ... and the writer side makes no content claim about whitespace-only lines" $W21
# ⛔ AND THE SCOPE OF THAT PREDICATE IS THE FIRST LINE, NOT THE FILE (review cycle 31, P2). The first fix stripped
# the WHOLE FILE while the loop (`head -1`) strips its FIRST LINE only, so a record whose first line is blank but
# carries content later was still split across the two sides — and the writer would quote a "standing line" that
# the floor reads as EMPTY. Both directions driven against the SAME file the loop reads.
mkdir -p "$T/o9y5/state"; printf '\nOK product=1 harness=1\n' > "$T/o9y5/state/product-class"
case "$(rsn "$T/o9y5")" in *"is EMPTY"*"whitespace-only record counts as empty"*) Y5b=0 ;; *) Y5b=1 ;; esac
ck "P12 [RED→GREEN] a record whose FIRST LINE is blank (content later) is EMPTY — the loop's scope, not a file-wide strip (got '$(rsn "$T/o9y5")')" $Y5b
mkdir -p "$T/o9y6/state"; printf 'OK product=0 harness=2\n\n' > "$T/o9y6/state/product-class"
case "$(rsn "$T/o9y6")" in *"already on disk"*"OK product=0 harness=2"*) Y6b=0 ;; *) Y6b=1 ;; esac
ck "P12 [RED→GREEN] ... while a record with a real first line and blank content below is still the standing line (got '$(rsn "$T/o9y6")')" $Y6b
# ⛔ AND THE ARM ORDER IS THE LOOP'S, NOT JUST ITS VOCABULARY (review cycle 31, P2 — measured as ALREADY TRUE, and
# pinned so it cannot drift back). A 0-byte file is BOTH unreadable-if-it-cannot-be-opened and empty-by-size, so the
# two sides only agree if the readability test comes FIRST: the loop tests `-e`, then `-r`, then emptiness, and a
# reordering here would make the writer promise "EMPTY (the failed write truncated it)" about a record the floor
# reports as UNREADABLE. Measured on this head: both sides say UNREADABLE.
mkdir -p "$T/o9y7/state"; : > "$T/o9y7/state/product-class"; chmod 000 "$T/o9y7/state/product-class" 2>/dev/null || :
if [ -e "$T/o9y7/state/product-class" ] && [ ! -r "$T/o9y7/state/product-class" ]; then
  _w7="$(rsn "$T/o9y7")"
  chmod 600 "$T/o9y7/state/product-class" 2>/dev/null || :
  case "$_w7" in *"UNREADABLE"*) [ "${_w7#*EMPTY}" = "$_w7" ] && Y7b=0 || Y7b=1 ;; *) Y7b=1 ;; esac
  ck "P12 [RED→GREEN] a 0-byte UNREADABLE record says UNREADABLE on the writer side too, never EMPTY (got '$_w7')" $Y7b
else
  chmod 600 "$T/o9y7/state/product-class" 2>/dev/null || :
  ck "P12 (skipped) cannot make the record unreadable on this box (running as root?)" 0
fi
# ⛔ A DIRECTORY ON THE RECORD PATH IS NOT AN EMPTY RECORD (review cycle 34, P2). `-s` is true for a directory and
# `head -1` on it fails, so BOTH sides collapsed that state into "EMPTY (a failed write truncates it)" — a false
# statement about the disk in the pair of functions whose job is to name the state that is really there.
# ⛔ AND IT LIVES OUTSIDE THE chmod GUARD ABOVE (review cycle 35, P1): it needs no permission at all, and nesting it
# inside the unreadable-record fixture is the cycle-30 defect a third time — on a root box the pins of the headline
# fix then never ran. The `else` above therefore prints exactly ONE skip line (the one assertion it replaces).
mkdir -p "$T/o9y8/state/product-class"
_p8="$(pc_state_note "$T/o9y8")"
case "$_p8" in
  *"NOT-A-FILE"*) [ "${_p8#*EMPTY}" = "$_p8" ] && Y8b=0 || Y8b=1 ;;
  *) Y8b=1 ;;
esac
ck "P12 [RED→GREEN] a DIRECTORY at state/product-class is reported as NOT-A-FILE by the loop, never EMPTY (got '$_p8')" $Y8b
_r8="$(rsn "$T/o9y8")"
case "$_r8" in *"NOT-A-FILE"*"nothing was truncated"*) Y9b=0 ;; *) Y9b=1 ;; esac
ck "P12 [RED→GREEN] ... and the writer side says the same thing about it (got '$_r8')" $Y9b
# ⛔ THESE THREE LIVE OUTSIDE THAT GUARD (review cycle 33, P2): they were nested inside the unreadable-record
# fixture, so on a ROOT box they never executed and the suite still exited 0 — the exact nesting the cycle-30 P1
# was about, reintroduced by the block that fixed cycle 32. Neither the zero-byte file-size limit nor a grep of
# `floor_order` needs any chmod at all.
# ⛔ NO WRITE IN floor_order CAN FAIL SILENTLY (review cycle 32, P2). The head ledger was a `mktemp` file appended
# to with `printf … >> "$w"` and the append was unchecked: on a full /tmp it failed, the `-s "$w"` tail branch fell
# through to `cat "$afile"`, and the function returned the backlog PLUS the head it had already printed — 5 lines
# from a 3-line backlog. Driven under the same zero-byte file-size limit the ENOSPC fixture uses: pipes ignore the
# limit, files do not, so the old form reproduces and the in-shell form is unaffected.
mkdir -p "$T/fl"; printf '34\n' > "$T/fl/p.txt"; printf '12\n34\n56\n' > "$T/fl/a.txt"
FLW="$( ( ulimit -f 0 2>/dev/null || :; floor_order 1 "$T/fl/p.txt" "$T/fl/a.txt" 2>/dev/null | tr '\n' ' ' ) )"
case "$FLW" in "34 12 56 "*) F1b=0 ;; *) F1b=1 ;; esac
ck "P8 [RED→GREEN] floor_order returns the backlog ONCE with the head first, even when no file can be written (got '$FLW')" $F1b
# and the mechanism is pinned, not just the behaviour: an append to a temp file is what made the failure possible
# ⛔ THE MECHANISM IS ANY WRITE-TO-A-FILE, NOT ONE VARIABLE NAME (review cycle 32): checking for `>> "$w"` let a
# ledger file under any other name through, and an append whose failure is unchecked is exactly what produced the
# duplicate order. floor_order needs NO output redirect at all — it prints to stdout and reads its two inputs — so
# the pin is that it contains none (an input redirect is `<`, which is allowed).
_fl_tmp="$(sed -n '/^floor_order() {/,/^}/p' "$LOOP" | grep -v '^[[:space:]]*#' | grep -c 'mktemp\|>>\|> *"\$' 2>/dev/null || :)"
[ "${_fl_tmp:-0}" = "0" ]
ck "P8 [RED→GREEN] floor_order keeps its ledger in the shell, with no output redirect and no temp file (measured: ${_fl_tmp:-0} sites)" $?
if mkdir -p "$T/o9y3/state" && printf 'OK product=1 harness=1\n' > "$T/o9y3/state/product-class" \
   && chmod 000 "$T/o9y3/state/product-class" 2>/dev/null && [ ! -r "$T/o9y3/state/product-class" ]; then
  _w3="$(rsn "$T/o9y3")"
  chmod 600 "$T/o9y3/state/product-class" 2>/dev/null || :
  case "$_w3" in *"UNREADABLE record"*"report UNREADABLE"*) Y3b=0 ;; *) Y3b=1 ;; esac
  ck "P12 [RED→GREEN] an UNREADABLE record: the writer has its own arm, not the already-on-disk one (got '$_w3')" $Y3b
else
  chmod 600 "$T/o9y3/state/product-class" 2>/dev/null || :
  ck "P12 (skipped) cannot make the record unreadable on this box (running as root?)" 0
fi
printf 'LISTING-FAILED the harness-label listing failed\n' > "$T/o9p/state/product-class"
OUTP3="$(runblock "$T/o9p")"
case "$OUTP3" in *"NOT a trustworthy floor measurement"*"LISTING-FAILED"*) Z7=0 ;; *) Z7=1 ;; esac
ck "P9 [RED→GREEN] ... and the STALE-queue case the degrade arm discloses is named too (got '${OUTP3:0:150}')" $Z7
# ⛔ A FAILED RECORD WRITE MUST SAY WHAT THE DISK HOLDS (review cycle 10, P2). The PENDING write runs first in
# the same function and normally SUCCEEDS, so the file holds THIS pass's PENDING line — the "PREVIOUS pass's"
# wording named the one state that cannot occur on the disk it was describing. Pinned as a text claim on both
# message sites (there are two read paths), since the failure is a wrong statement to the operator, not a
# behaviour: a mutation back to "PREVIOUS pass's" was otherwise invisible (measured 118/0).
_prevleft="$(grep -c "record on disk is the PREVIOUS pass" "$REFRESH" 2>/dev/null || :)"
[ "${_prevleft:-0}" = "0" ]
ck "P12 [RED→GREEN] no message claims the record on disk is the PREVIOUS pass's (measured: ${_prevleft:-0} sites)" $?
# The messages no longer guess WHICH state is on disk: they read it (`record_state_note`), so the pin is that
# every failed-record message routes through that reader and none of them re-asserts a state by hand.
# ⛔ AND THE COUNT MUST NOT LEAVE A SITE FREE (review cycle 35, P2): `-ge 3` against FOUR shipped sites left the
# split-succeeded-but-record-write-failed arm unstoppable — it could be mutated to hardcode
# "an EMPTY record (the failed write truncated it)" and every assertion stayed green, because no fixture drove that
# arm. The count is now exact, AND the arm is driven below (a writable `$O` with a READ-ONLY record, listing
# succeeded) so the sentence must name what is really on disk.
_note_sites="$(grep -c 'record_state_note "\$o"' "$REFRESH" 2>/dev/null || :)"
[ "${_note_sites:-0}" -eq 4 ]
ck "P12 [RED→GREEN] all FOUR failed-record messages read the record instead of asserting its state (${_note_sites:-0} sites)" $?
# the driven fourth arm: the record cannot be written but the split SUCCEEDED, so the warning must quote the
# record the disk really holds — not a hardcoded EMPTY, and not a claim that nothing is there.
mkdir -p "$T/wo9/state"; printf '12\n34\n' > "$T/wo9/candidates.txt"
printf 'OK product=0 harness=3\n' > "$T/wo9/state/product-class"; chmod 400 "$T/wo9/state/product-class"
if [ ! -w "$T/wo9/state/product-class" ]; then
  OUTW9="$(wk "$T/wo9" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 34" 2>&1)"
  chmod 600 "$T/wo9/state/product-class" 2>/dev/null || :
  case "$OUTW9" in
    *"the record already on disk (\"OK product=0 harness=3\")"*) W9=0 ;;
    *) W9=1 ;;
  esac
  ck "P12 [RED→GREEN] a split that RAN but could not record its class names the record really on disk (got '$(printf '%s' "$OUTW9" | grep -o 'the record already on disk ([^)]*)' | head -1)')" $W9
  case "$OUTW9" in *"an EMPTY record"*|*"carry NO record"*) W10=1 ;; *) W10=0 ;; esac
  ck "P12 [RED→GREEN] ... and does not assert a state it never read" $W10
else
  chmod 600 "$T/wo9/state/product-class" 2>/dev/null || :
  ck "P12 (skipped) cannot make the record read-only on this box (running as root?) — names the record on disk" 0
  ck "P12 (skipped) ... — does not assert a state it never read" 0
fi
grep -q 'is EMPTY (the failed write truncated it)' "$REFRESH"
ck "P12 [RED→GREEN] ... and the truncated-to-empty case — the one a full disk produces — is named" $?
# (e) the split RAN and MEASURED zero product candidates: the queue is empty but the class is KNOWN.
# ⛔ WITHOUT THIS ARM THE OK* BRANCH IS NEVER EXECUTED (measured: a `: > "$O/.batch"; K=0` opening it
# left every assertion GREEN) — a MEASURED-empty read is exactly the routine all-harness pass a
# product repo sees every day, so it is the branch most likely to be edited and the last one tested.
mkdir -p "$T/o9e/state"; printf '42\n43\n' > "$T/o9e/candidates.txt"
printf 'OK product=0 harness=3\n' > "$T/o9e/state/product-class"
# ⛔ THE RECORD MUST AGREE WITH THE DISK FOR THIS TO BE A MEASUREMENT (review cycle 22, P2): the arm checks BOTH
# numbers now, so a record claiming harness=3 beside a 0-line file is (correctly) a stale record, not the
# measured-empty case this assertion is about.
printf '44\n45\n46\n' > "$T/o9e/candidates.harness.txt"
OUTE="$(runblock "$T/o9e")"
case "$OUTE" in *"BATCH=[42 43]"*"K=[2]"*) A8=0 ;; *) A8=1 ;; esac
ck "P9 [RED→GREEN] a MEASURED-empty queue leaves the batch intact too — got '$OUTE'" $A8
case "$OUTE" in *"split RAN and found none"*"OK product=0 harness=3"*) A9=0 ;; *) A9=1 ;; esac
ck "P9 [RED→GREEN] ... and the OK* arm reports the MEASUREMENT it was given (got '$OUTE')" $A9
case "$OUTE" in *"UNKNOWN"*) A10=1 ;; *) A10=0 ;; esac
ck "P9 [RED→GREEN] ... and it does NOT call a measured zero an UNKNOWN class (got '$OUTE')" $A10
# (f) ⛔ EXACT MATCH, OR A NEIGHBOUR'S NUMBER IS COUNTED (review cycle 3, P3). The batch walk counts a
# product entry with `grep -qx`, and the only fixture that drove it used product `99` against batch
# `42 43` — no prefix overlap, so loosening `-qx` to `-q` stayed GREEN. With `-q`, product `4` matches
# batch entry `42`, PB becomes 1 and the `product-floor unmet` line is SUPPRESSED: the floor reports
# itself MET over a batch holding zero product work, the one direction that must never be reported.
mkdir -p "$T/o9f/state"; printf '42\n43\n' > "$T/o9f/candidates.txt"; printf '4\n' > "$T/o9f/candidates.product.txt"
printf 'OK product=1 harness=0\n' > "$T/o9f/state/product-class"
OUTF9="$(runblock "$T/o9f")"
case "$OUTF9" in *"product=0/2 in this batch"*) A11=0 ;; *) A11=1 ;; esac
ck "P9 [RED→GREEN] product '4' is NOT counted against batch '42 43' (an EXACT match, not a prefix) — got '$OUTF9'" $A11
case "$OUTF9" in *"product-floor unmet"*) A12=0 ;; *) A12=1 ;; esac
ck "P9 [RED→GREEN] ... so the unmet floor is still REPORTED over a batch with no product work (got '$OUTF9')" $A12
# (g) ⛔ A PASS THAT NEVER REACHED THE SPLIT MUST NOT RE-DISPLAY THE LAST ONE'S MEASUREMENT (review
# cycle 3, P2). `state/product-class` is written at the END of a pass or not at all, so every abort above
# it (a refused pool read — #1736's 131-pass blind intake — or a budget that cannot buy a candidate)
# left the PREVIOUS pass's `OK product=0` standing, and this arm printed "the split RAN and found none"
# as THIS pass's measurement. ⛔ THE INVALIDATION IS INSIDE THE WRITER, NOT AT PASS START (review cycle 15,
# P2): `write_product_queues` writes `PENDING` as its FIRST action and every arm below overwrites it, so a
# pass that aborts BEFORE the writer leaves the previous record standing — which is correct, because
# neither queue file changed. A pass that reaches the writer and dies mid-split leaves `PENDING`. Restoring a
# pass-ENTRY invalidation is the cycle-6 P1 (a blind intake reported on a healthy box) — do not.
# Either way the loop must report `PENDING` as an UNREAD class and never claim a measurement from it.
mkdir -p "$T/o9g/state"; printf '42\n43\n' > "$T/o9g/candidates.txt"
printf 'PENDING this pass has started but has not recorded a product class yet — no split has run, so this is NOT a measurement and NOT a finding about product work (the pass aborted, or is still running)\n' > "$T/o9g/state/product-class"
OUTG="$(runblock "$T/o9g")"
case "$OUTG" in *"reason=PENDING"*"queue=READ(3)"*) A13=0 ;; *) A13=1 ;; esac
ck "P9 [RED→GREEN] a PENDING record is reported as an UNKNOWN class, with its reason (got '$OUTG')" $A13
case "$OUTG" in *"split RAN"*) A14=1 ;; *) A14=0 ;; esac
ck "P9 [RED→GREEN] ... and it does NOT claim the last pass's measurement as this pass's (got '$OUTG')" $A14
# The invalidation only helps if the SHIPPED pass writes it — anchored to the printf at line start, so a
# comment cannot satisfy the pin (the cycle-2 lesson: a phrase-only grep was satisfied by its own comment).
# ⛔ THE WRITE NOW GOES THROUGH A CHECKED HELPER (review cycle 33, P2), so the pin follows the CALL — still
# anchored at line start and still requiring the PENDING text, so a comment cannot satisfy it.
grep -Eq '^  if ! write_record "\$o" .PENDING this pass has started' "$REFRESH"
ck "P9 [RED→GREEN] the SHIPPED refresh invalidates the class before it writes a queue (line-start anchored, inside the writer)" $?
# ⛔ THE RECORD DESCRIBES THE TWO QUEUE FILES, SO ONLY THE THING THAT WRITES THEM MAY INVALIDATE IT
# (review cycle 6, P1). The invalidation used to run at PASS ENTRY, ~1,400 lines before the first byte of
# either queue: every pass that refused at the environment check, the budget or the pool read replaced a
# record that was still a byte-true description of the queues with `PENDING`, and the loop reported a
# BLIND INTAKE on a healthy box (measured: the pass exits at `gh_env_verdict || exit` with both queue
# files untouched). Placed inside `write_product_queues`, every arm still overwrites it — so a pass that
# dies mid-split cannot leave the previous measurement standing — while a pass that never reaches the
# writer leaves the previous record alone, which is still true because nothing it describes changed.
_fstart="$(grep -n '^write_product_queues() {' "$REFRESH" | head -1 | cut -d: -f1)"
_fend="$(awk -v s="${_fstart:-0}" 'NR>s && /^}/ {print NR; exit}' "$REFRESH")"
_pend="$(grep -n '^  if ! write_record "\$o" .PENDING this pass has started' "$REFRESH" | head -1 | cut -d: -f1)"
# the writer's first write of EITHER queue file: the invalidation must precede it
_qwrite="$(awk -v s="${_fstart:-0}" -v e="${_fend:-0}" 'NR>s && NR<e && /candidates\.(product|harness)\.txt/ {print NR; exit}' "$REFRESH")"
case "$_fstart$_fend$_pend$_qwrite" in ''|*[!0-9]*) P9SU=1 ;; *) P9SU=0 ;; esac
ck "P9 (setup) the writer, its invalidation and its first queue write are locatable (fn=$_fstart-$_fend pend=$_pend qwrite=$_qwrite)" $P9SU
[ "$_pend" -gt "$_fstart" ] && [ "$_pend" -lt "$_qwrite" ]
ck "P9 [RED→GREEN] the invalidation sits INSIDE the writer and BEFORE its first queue write (fn=$_fstart < pend=$_pend < qwrite=$_qwrite)" $?
# ⛔ AND NOTHING ELSE INVALIDATES IT: an entry-time write (or any second one) re-introduces the false
# blind intake for every pass that refuses before the writer.
[ "$(grep -c 'PENDING this pass has started' "$REFRESH")" -eq 1 ]
ck "P9 [RED→GREEN] the pass invalidates the record in exactly ONE place — the writer, not at entry (a second invalidation is a false blind intake)" $?
# ⛔ AND A DELIBERATE SKIP MUST NOT TOUCH THE RECORD AT ALL (review cycles 4-6). With the invalidation
# inside the writer, the #1984 unchanged-pool skip leaves the previous record standing by construction —
# the queues did not change, so the record is still true. Pinned so a future "fix" cannot put a
# PENDING-then-restore dance back into that branch.
_skif="$(grep -n '^  if \[ "\$AGE" -ge 0 \]' "$REFRESH" | head -1 | cut -d: -f1)"
_skex="$(awk -v s="${_skif:-0}" 'NR>s && /^    exit 0$/ {print NR; exit}' "$REFRESH")"
case "$_skif$_skex" in ''|*[!0-9]*) P9SK=1 ;; *) P9SK=0 ;; esac
ck "P9 (setup) the unchanged-pool skip branch and its exit are locatable (skif=$_skif skex=$_skex)" $P9SK
_skin="$(awk -v s="${_skif:-1}" -v e="${_skex:-0}" 'NR>s && NR<e && /state\/product-class/ {print NR}' "$REFRESH")"
[ -z "$_skin" ]
ck "P9 [RED→GREEN] a SKIPPED pass does NOT touch state/product-class — the record is still true (got '${_skin:-'<none>'}')" $?

# ⛔ AND A SHORTFALL IS UNMET, NOT ONLY A ZERO (review cycle 5, P2). The arm tested `PB -eq 0`, so with
# `PRODUCT_FLOOR=2` a batch that filled one product slot printed NO unmet line: the count line said
# `product=1/2 in this batch (floor=2)` and the queue token — the one field that separates "no product
# work" from "we could not read the class" — was never emitted. Latent at the default floor of 1.
mkdir -p "$T/o9s/state"; printf '12\n34\n56\n' > "$T/o9s/candidates.txt"
printf '34\n56\n' > "$T/o9s/candidates.product.txt"; printf 'OK product=2 harness=1\n' > "$T/o9s/state/product-class"
OUTS9="$(runblock "$T/o9s" "$(printf '34\n12\n')" 2)"
case "$OUTS9" in *"product=1/2 in this batch (floor=2)"*) S1F=0 ;; *) S1F=1 ;; esac
ck "P10 [RED→GREEN] floor=2 with one product slot filled reports product=1/2 — got '$OUTS9'" $S1F
case "$OUTS9" in *"product-floor unmet"*"SHORTFALL"*"queue=READ(3)"*) S2F=0 ;; *) S2F=1 ;; esac
ck "P10 [RED→GREEN] ... and a SHORTFALL is reported as unmet, carrying the queue token (got '$OUTS9')" $S2F
# ⛔ THE WINDOW NAMED IN A REASON MUST BE THE WINDOW THAT WAS READ (review cycle 5, P2). The listing call
# uses `"$WPQ_LISTING_LIMIT"`; both LISTING-TRUNCATED strings used to TYPE `--limit 500`, so raising the
# constant would leave the operator told about a window the pass no longer used. Pinned on the shipped
# lines: the record must interpolate, and the constant must be its argument.
# ⛔ THE PIN READS THE LINE IT NAMES (review cycle 7, P2). A `grep -A1` window over the record's printf also
# captured the WARN line below it, which contains `WPQ_LISTING_LIMIT` — so the assertion passed with the
# RECORD typing a literal, i.e. exactly the defect it names. Now the record's own printf line is the only
# input.
_lt="$(grep -m1 -F "printf 'LISTING-TRUNCATED" "$REFRESH" 2>/dev/null || :)"
grep -q -- '--limit %s' <<<"$_lt" && grep -q 'WPQ_LISTING_LIMIT' <<<"$_lt"
ck "P10 [RED→GREEN] the LISTING-TRUNCATED record interpolates WPQ_LISTING_LIMIT instead of typing a window (got '${_lt:0:80}')" $?

# ⛔ AND THE INDICATOR NEEDS A **MET** CASE (review cycle 3, P1). Only the unmet arms were driven, so
# freezing the counter (`&& PB=$PB`) left every gate green while a SATISFIED floor was reported as
# unmet on every batch — the routine line printed in the same words as the real failure, which is the
# masking this whole block exists to remove.
mkdir -p "$T/o9f/state"; printf '12\n34\n56\n' > "$T/o9f/candidates.txt"
printf '34\n56\n' > "$T/o9f/candidates.product.txt"; printf 'OK product=2 harness=1\n' > "$T/o9f/state/product-class"
OUTF9="$(runblock "$T/o9f" "$(printf '34\n12\n')")"
case "$OUTF9" in *"product=1/2 in this batch (floor=1)"*) F1=0 ;; *) F1=1 ;; esac
ck "P9 [RED→GREEN] a batch CONTAINING a product candidate reports product=1/2 — got '$OUTF9'" $F1
case "$OUTF9" in *"floor unmet"*) F2=1 ;; *) F2=0 ;; esac
ck "P9 [RED→GREEN] ... and does NOT claim the floor is unmet (got '$OUTF9')" $F2

echo
echo "── P12: the two WIRES that make the floor reachable, and the flag that makes it safe ─────"
# ⛔ A FUNCTION NOBODY CALLS IS NOT A FEATURE (review cycle 3, P1). `write_product_queues` is extracted
# and driven by P7 — which proves the function, and NOTHING about whether the daemon ever calls it.
# Measured: deleting the single call site in `refresh-candidates.sh` left this suite at 71/0 and
# refresh-scout at 284/0, i.e. the floor's entire intake could be removed with every gate green, and
# every cycle would then print `unmet … UNKNOWN`. Anchored to the code line, because the plain
# `grep 'candidates.product.txt'` that used to stand here is satisfied by the comments naming the file.
# ⛔ THE ARGUMENTS ARE PART OF THE WIRE (review cycle 7, P1). A prefix match (`… "\$O" "\$OR"`) is
# satisfied after dropping the THIRD argument, and `prepos` empty makes every pass record
# `NOT-A-PRODUCT-REPO` — the floor reports `N/A` forever, the "this is not a finding about product work"
# masking, with the suite green. Pinned to the whole call.
grep -Eq '^[[:space:]]*write_product_queues "\$O" "\$OR" "\$\{PRODUCT_REPOS:-\}"[[:space:]]*$' "$REFRESH"
ck "P12 [RED→GREEN] the refresh pass CALLS write_product_queues with \$O, \$OR AND the PRODUCT_REPOS list (the whole wire)" $?
# … and the knob itself must be a real assignment, not merely a word in a comment (`grep -q PRODUCT_REPOS`
# was satisfied by the comments naming it, so deleting the default stayed green).
grep -Eq '^PRODUCT_REPOS="\$\{PRODUCT_REPOS:-[a-zA-Z0-9._/-]+\}"[[:space:]]*$' "$REFRESH"
ck "P12 [RED→GREEN] PRODUCT_REPOS has a shipped default assigned at line start (not just comments naming it)" $?
# … and the label filter must be the label that CLASSIFIES, inside the listing call (`--label harness` is a
# prefix of `--label harness-label`, an exact-match filter returning zero rows, which classifies every
# candidate PRODUCT — the manufactured-class direction the polarity comment forbids).
# ⛔ THE WHOLE ARGV, NOT JUST THE LABEL (review cycle 10, P2). The pin wildcarded everything between
# `issues` and `--label`, so `--limit 100` (the reasons keep naming the constant while the pass reads 100
# — the cycle-5 defect, reintroduced through the CALL) and `--state closed` (every OPEN harness issue then
# classifies PRODUCT: manufactured product work, which the degrade contract forbids) both left the suite
# green. Pinned as the exact argv, in order, with no literal limit.
# ⛔ …AND THE PROJECTION (review cycle 21, P2). The pin stopped at `--label harness`, leaving `--jq
# '.[].number'` free: it is what the split reads FOR ABSENCE, so `--jq '.[]'` — which yields whole issue
# OBJECTS — still left 153/0 while inverting the split (every harness-labelled candidate classified PRODUCT,
# the manufactured-work direction invariant 3 forbids). One exact argv, projection included.
grep -Eq '^[[:space:]]*&& rest_list issues --repo "\$repo" --state open --limit "\$WPQ_LISTING_LIMIT" --label harness --jq '"'"'\.\[\]\.number'"'"'([[:space:]]|>|$)' "$REFRESH"
ck "P12 [RED→GREEN] the harness listing's argv is exact INCLUDING the jq projection '.[].number' (the numbers, not whole objects)" $?
# ⛔ AND A POINTER MUST POINT AT THE RIGHT LINE (review cycle 21, P2). The record-write warning tells the
# operator to "read the line above for what happened", but the line that says what happened (`split FAILED to
# write …`) is printed AFTER it — so on a pass where BOTH the queues and the record failed, the one sentence
# that explains the failure sent the operator to the wrong line. The wording is graded AND the order is
# checked, because either alone is satisfiable while the message still points the wrong way.
grep -q 'read the PASS LINE BELOW' "$REFRESH"
ck "P12 [RED→GREEN] the record-write warning points at the PASS LINE BELOW, where that line actually is" $?
_offwarn=$(_pos="$(grep -n 'read the PASS LINE BELOW' "$REFRESH" | head -1 | cut -d: -f1)"; echo "$_pos")
_offpass=$(_pos="$(grep -n 'split FAILED to write' "$REFRESH" | head -1 | cut -d: -f1)"; echo "$_pos")
[ -n "$_offwarn" ] && [ -n "$_offpass" ] && [ "$_offwarn" -lt "$_offpass" ]
ck "P12 [RED→GREEN] ... and that line really is printed below it (warn line $_offwarn < pass line $_offpass)" $?
# ⛔ AND THE "NOT RENDERED" LIST IS CHECKED AGAINST THE TEMPLATE (review cycle 13, P2). Every name in the
# README's knob table with no `__NAME__` placeholder must be named in that paragraph — it was hand-kept and
# had drifted by one (`MERGE_STALL_MIN` was missing while being exactly the silent no-effect it warns about).
# Computed here rather than eyeballed: a knob added to the table without a placeholder reddens this.
_tbl="$(awk '/^\| `[A-Z_]+` \|/{gsub(/^\| `/,"");gsub(/`.*/,"");print}' "$HERE/README.md" 2>/dev/null | sort -u)"
_ren="$(grep -o '__[A-Z_]*__' "$HERE/launchd.plist.template" 2>/dev/null | sed 's/__//g' | sort -u)"
_missing=""
# Scoped to the PARAGRAPH, not the file: the table immediately above names every one of these knobs, so a
# whole-file grep is satisfied by the row it is describing (measured: removing MERGE_STALL_MIN from the
# paragraph left the check green because its table row still matched).
_para="$(awk '/NOT rendered into the plist/{f=1} f{print} f && /^$/{exit}' "$HERE/README.md")"
# Excluded from THIS paragraph's scope on purpose, and named here so the exclusion is visible rather than
# implied: the three wall-clock timeouts are the phrase "the three wall-clock timeouts" in that sentence, and
# the AGENT_GH_GATE_* family is documented in its own gate section. Everything else that has no placeholder
# must be named explicitly.
for _k in $(comm -23 <(printf '%s\n' "$_tbl") <(printf '%s\n' "$_ren")); do
  case "$_k" in LANE_TIMEOUT|REVIEW_TIMEOUT|FIX_TIMEOUT|AGENT_GH_GATE_*) continue ;; esac
  case "$_para" in *"\`$_k\`"*) : ;; *) _missing="$_missing $_k" ;; esac
done
[ -n "$_tbl" ] && [ -n "$_ren" ] && [ -n "$_para" ] && [ -z "$_missing" ]
ck "P12 [RED→GREEN] every unrendered knob in the README table is named in the NOT-rendered paragraph (missing:'${_missing:-'<none>'}')" $?
# ⛔ AND THE SATURATION FLAG HAS A PRODUCER (review cycle 3, P1). P7's truncation arm sets
# `REST_WINDOW_FILLED` in its own `rest_list` stub, so it proves the CONSUMER against a hand-set flag;
# the only thing that can set that flag in production is two lines in the shipped `rest_list`, and
# nothing read them. Measured: deleting both left 71/0 and 284/0 — the saturation guard permanently
# dead, in the one direction the design forbids (an unseen harness row classified PRODUCT).
RLF="$T/rest-list.sh"
sed -n '/^rest_list() {/,/^}/p' "$REFRESH" > "$RLF"
[ -s "$RLF" ] && grep -q 'REST_WINDOW_FILLED' "$RLF"
ck "P12 (setup) the shipped rest_list extracts and mentions the saturation flag" $?
runrest() { # <rows-on-the-page> <advertise-next-page: 0|1> -> prints the flag the SHIPPED code set
  (
    RROWS="$1"; RMORE="$2"
    OR="daniel-ospina/tortoise"
    rest_fail() { return 1; }
    gh() { # `gh api -i <url>`: a page with $RROWS rows, advertising a next page when $RMORE=1
      printf 'HTTP/1.1 200 OK\n'
      [ "${RMORE:-0}" = "1" ] && printf 'Link: <https://api.github.com/x?page=2>; rel="next"\n'
      printf '\n'
      jq -n --argjson n "${RROWS:-0}" '[range(0;$n) | {number: .}]'
    }
    . "$RLF" || exit 1
    rest_list issues --repo "daniel-ospina/tortoise" --limit 100 >/dev/null 2>&1 || :
    printf 'FILLED=%s\n' "${REST_WINDOW_FILLED:-unset}"
  ) 2>&1
}
SATP="$(runrest 100 1)"
case "$SATP" in *FILLED=1*) S1=0 ;; *) S1=1 ;; esac
ck "P12 [RED→GREEN] the SHIPPED rest_list SETS the flag when the window fills with a next page advertised — got '$SATP'" $S1
SATN="$(runrest 40 0)"
case "$SATN" in *FILLED=0*) S2=0 ;; *) S2=1 ;; esac
ck "P12 [RED→GREEN] ... and leaves it CLEAR for a short final page with no next page — got '$SATN'" $S2

# ⛔ THE COUNTER ITSELF IS DRIVEN (review cycle 31, P2): making a skip count as a pass left every assertion above
# green, because the fixtures' own skip arms are what they are. The claim "a skipped arm is not a pass" is
# checkable in three lines, so it is checked rather than asserted in prose.
_P_PRE=$PASS; _S_PRE=$SKIP
ck "self-test (skipped) a skipped arm" 0
# `ck`'s argument is a FAILURE flag (0 = the assertion held), so the sentinel is named for failure too — the
# first version called it OK and reddened itself.
SELFTEST_BAD=0
[ "$PASS" -eq "$_P_PRE" ] || SELFTEST_BAD=1
[ "$SKIP" -eq "$((_S_PRE+1))" ] || SELFTEST_BAD=1
ck "P0 [RED→GREEN] an arm marked as skipped raises SKIP and leaves PASS alone" $SELFTEST_BAD

echo
echo "═══════════════════════════════════════════════"
# ⛔ THE COUNT IS PART OF THE VERDICT (review cycle 31, P2). A deleted pin, or a fixture quietly skipped, shrinks
# the executed total while the summary still reads "0 failed" — the shape that let a P1 ship green in cycle 30.
# MIN_CHECKS is the number of assertions that must actually EXECUTE on this platform (measured, not typed from
# ambition: raise it when you add pins, never lower it to make a run pass).
# ⛔ THE FLOOR IS ON PASS+SKIP — the assertions that EXIST — not on PASS alone (review cycle 33). PASS alone is
# platform-dependent (a root box legitimately skips the chmod arms), so a floor on it either reddens on Linux
# cells or is set so low it stops detecting anything. Every skip arm prints one line per assertion it replaces,
# so this total is the same everywhere; a deleted pin, or a real assertion converted into a skip, lowers it.
MIN_CHECKS=235
if [ "$((PASS+SKIP))" -lt "$MIN_CHECKS" ]; then
  FAIL=$((FAIL+1))
  FAILED_LINES="$FAILED_LINES$((PASS+SKIP)) assertions present, below the required ${MIN_CHECKS} — pins went missing
"
  printf '  ❌ only %s assertions are present (expected at least %s) — pins went missing\n' "$((PASS+SKIP))" "$MIN_CHECKS"
fi
echo "   $PASS passed, $SKIP skipped, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '%s' "$FAILED_LINES" | sed 's/^/  failed: /'
  exit 1
fi
