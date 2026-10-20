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

PASS=0; FAIL=0; FAILED_LINES=""
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_LINES="$FAILED_LINES$1
"; printf '  ❌ %s\n' "$1"; }
ck() { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

[ -f "$LOOP" ] || { echo "❌ missing $LOOP"; exit 2; }
[ -f "$REFRESH" ] || { echo "❌ missing $REFRESH"; exit 2; }

# ⛔ THE FUNCTIONS ARE EXTRACTED FROM THE SHIPPED FILE, so this suite executes the code the daemon runs
# rather than a copy that can drift. A missing function is a RED, not a skip.
FNS="$T/fns.sh"
{
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
ck "P3 [RED→GREEN] a floor above a BATCH=1 is clamped to 1 (the floor can never exceed the batch)" $?

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
GOT="$(order 1 | tr '\n' ' ' | sed 's/ $//')"; RC=$?
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
# ⛔ POSITION IS THE CONTRACT (indicator (c)): the floor may not delay a batch, so its ordering code must
# come after the merge-priority gate's decision (`GATE_WHY`). A text pin is the honest instrument here —
# the gate is driven by its own suite, and re-driving it would be a second implementation of it.
LINE_GATE="$(grep -n 'GATE_WHY="$(mp_reason' "$LOOP" | head -1 | cut -d: -f1)"
LINE_FLOOR="$(grep -n 'product-floor unmet' "$LOOP" | head -1 | cut -d: -f1)"
[ -n "$LINE_GATE" ] && [ -n "$LINE_FLOOR" ] && [ "$LINE_FLOOR" -gt "$LINE_GATE" ]
ck "P6 [RED→GREEN] the floor's code sits AFTER the merge-priority gate (gate=$LINE_GATE floor=$LINE_FLOOR)" $?
# ⛔ AND IT MUST CARRY THE QUEUE-STATE TOKEN (indicator (b)): without it, `product-floor unmet` on a
# blind intake reads as "there is no product work", which is the #2042/#1931 masking failure.
grep -q 'product-floor unmet' "$LOOP" && grep -q 'queue=\$(queue_state_token)' "$LOOP"
ck "P6 [RED→GREEN] the unmet line names the queue state, so blindness is not read as 'no product work'" $?
# An unmet floor must not close the lane: the same branch must still reach the batch dispatch.
grep -q 'product-floor unmet' "$LOOP" && ! grep -q 'exit .*product-floor' "$LOOP"
ck "P6 [RED→GREEN] an unmet floor NEVER refuses the batch (no exit on the unmet path)" $?
# ⛔ AND IT MAY NOT EMPTY THE BATCH EITHER (cycle-1 review, P1): "log and degrade" means the issues this
# pass already selected are still dispatched. The failure to exclude is `: > "$O/.batch"; K=0` on the
# unmet path — dispatch then stalls until a product candidate appears, which is exactly the
# don't-cap-the-fleet rule the issue states. A spelling pin, stated as one: the unmet arms contain no
# batch-truncation or counter reset.
awk '/product-floor unmet/{f=1;next} f&&/^ *fi *$/{f=0} f&&(/: > "\$O\/\.batch"/||/K=0/) {print "TRUNCATES"; exit}' "$LOOP" | grep -q TRUNCATES
P6_TRUNC=$?
[ "$P6_TRUNC" -ne 0 ]
ck "P6 [RED→GREEN] the unmet arms never truncate the batch or reset K (a floor is not a gate)" $?
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
{ [ -n "$OKB" ] && ! printf '%s\n' "$OKB" | grep -q 'product class UNKNOWN'; }
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
grep -q -- '--label harness' "$REFRESH"
ck "P7 [RED→GREEN] the harness class comes from the harness LABEL, read from the API" $?
grep -q 'PRODUCT_FLOOR' "$LOOP"
ck "P7 [RED→GREEN] orch-loop.sh reads PRODUCT_FLOOR" $?
# ⛔ AND THE REFRESH'S SPLIT IS DRIVEN, NOT GREPPED (cycle-1 review, P1). Two defects survived the
# grep-only version: the inline block called a helper that lives in orch-loop.sh — the refresh
# runs as a CHILD process and never sources it, so the operator's line printed NO COUNTS on every pass
# under `2>/dev/null`; and the failed-listing polarity (a read that did not answer must classify
# everything as HARNESS, never manufacture product work) had no assertion at all, so inverting it left
# the suite green. `write_product_queues` is extracted from the shipped refresh and driven here, both
# arms, with a stubbed `rest_list`.
WFNS="$T/wfns.sh"
sed -n '/^write_product_queues() {/,/^}/p' "$REFRESH" > "$WFNS"
[ -s "$WFNS" ] && grep -q 'write_product_queues()' "$WFNS"
ck "P7 (setup) the refresh's split function extracts from the shipped file" $?
wk() { # <O> <OR> <PRODUCT_REPOS> <rest_list-rc> [harness-list] [window-filled] [core-now] [core-reserve]
  local o="$1" repo="$2" pre="$3" rc="$4" lst="${5:-}" wf="${6:-0}" cn="${7:-}" cr="${8:-}"
  (
    O="$o"; CORE_NOW="$cn"; CORE_RESERVE="$cr"; REST_WINDOW_FILLED="$wf"
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
# A split that RAN and found nothing is `OK product=0` — the measurement the dispatch line must repeat as
# a measured absence rather than as an unread class (review cycle 2b, P2).
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 34 56" >/dev/null
PROD0="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PROD0" = "0" ] && case "$(pcwhy "$T/wo")" in OK*product=0*) W1Z=0 ;; *) W1Z=1 ;; esac
ck "P7 [RED→GREEN] an all-harness backlog records OK product=0 (a MEASUREMENT), never NOT-A-PRODUCT-REPO (got '$(pcwhy "$T/wo")')" "${W1Z:-1}"
# ⛔ THE FAILED-READ ARM IS THE ONE THAT CAN INVENT WORK: an unanswered listing must leave the product
# queue EMPTY (everything harness) and say why.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
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
OUTB="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 10 20)"
PB0="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PB0" = "0" ]
ck "P7 [RED→GREEN] a spent budget lists nothing and manufactures no product work (product=$PB0)" $?
case "$(pcwhy "$T/wo")" in BUDGET-SKIPPED*) W5=0 ;; *) W5=1 ;; esac
ck "P7 [RED→GREEN] ... and records BUDGET-SKIPPED (got '$(pcwhy "$T/wo")')" $W5
# A repo outside PRODUCT_REPOS is all-harness by definition, and costs NO call at all.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTR="$(wk "$T/wo" daniel-ospina/agent-infra daniel-ospina/tortoise 0 "12 56")"
PRODR="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PRODR" = "0" ]
ck "P7 [RED→GREEN] a repo OUTSIDE PRODUCT_REPOS is all-harness (product=$PRODR)" $?
case "$OUTR" in *"not in PRODUCT_REPOS"*) W3=0 ;; *) W3=1 ;; esac
ck "P7 [RED→GREEN] ... and names the knob that decides it (got '$OUTR')" $W3
case "$(pcwhy "$T/wo")" in NOT-A-PRODUCT-REPO*) W3R=0 ;; *) W3R=1 ;; esac
ck "P7 [RED→GREEN] ... and records NOT-A-PRODUCT-REPO, which the loop reports as N/A (got '$(pcwhy "$T/wo")')" $W3R

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

echo
echo "═══════════════════════════════════════════════"
echo "   $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '%s' "$FAILED_LINES" | sed 's/^/  failed: /'
  exit 1
fi
