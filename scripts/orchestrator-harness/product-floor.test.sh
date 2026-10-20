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
echo "── P9: the split's budget gate and its write are CHECKED, not assumed ─────────────────────"
# ⛔ THE GATE MUST RESERVE THE LISTING'S OWN COST (this lane's cycle-2 review, P2). `--limit 500` pages
# at 100 rows per request, so the read costs UP TO FIVE core requests; the old test certified a pass
# with a SINGLE request of headroom as affordable, which approves a five-request read on a budget that
# stops being able to pay for it mid-listing — and a half-read exclusion set is classified as PRODUCT,
# the one direction the polarity above forbids. Driven at the boundary from both sides: reserve 20 +
# five requests = 25, so 24 must be refused and 25 must split.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTH1="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 24 20)"
PH1="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PH1" = "0" ]
ck "P9 [RED→GREEN] a pass with ONE request of headroom is NOT affordable for a 5-page listing (product=$PH1)" $?
case "$(pcwhy "$T/wo")" in BUDGET-SKIPPED*needs=25*) H1=0 ;; *) H1=1 ;; esac
ck "P9 [RED→GREEN] ... and the reason names what the listing NEEDED, not just what was left (got '$(pcwhy "$T/wo")')" $H1
# The same pass with the full cost available DOES split — a gate that refuses everything is not a gate.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTH2="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 25 20)"
PH2="$(tr '\n' ' ' < "$T/wo/candidates.product.txt" | sed 's/ $//')"
[ "$PH2" = "34" ]
ck "P9 [RED→GREEN] a pass that CAN afford the listing splits normally (product='$PH2')" $?
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56" 0 24 20 >/dev/null
case "$(pcwhy "$T/wo")" in BUDGET-SKIPPED*) H2=0 ;; *) H2=1 ;; esac
ck "P9 [RED→GREEN] ONE unit short of the listing is still refused (the constant is pinned on both sides, got '$(pcwhy "$T/wo")')" $H2
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
ck "P9 [RED→GREEN] a split whose write FAILED leaves the whole backlog as HARNESS ('$HARNX')" $?
case "$(pcwhy "$T/wo")" in WRITE-FAILED*) X1=0 ;; *) X1=1 ;; esac
ck "P9 [RED→GREEN] ... and records WRITE-FAILED rather than an OK it did not measure (got '$(pcwhy "$T/wo")')" $X1
case "$OUTX" in *"split: product"*) X2=1 ;; *) X2=0 ;; esac
ck "P9 [RED→GREEN] ... and prints NO counts it did not measure (got '$OUTX')" $X2
case "$OUTX" in *"split FAILED to write"*) X3=0 ;; *) X3=1 ;; esac
ck "P9 [RED→GREEN] ... and says the write failed on the pass line (got '$OUTX')" $X3
rmdir "$T/wo/candidates.product.txt" 2>/dev/null || :

echo
echo "── P10: the UNMET block is EXECUTED, and it leaves the batch intact ────────────────────────"
# ⛔ NO SUITE RAN THIS BLOCK (this lane's cycle-2 review, P1; re-verified after the merge: a
# `: > "$O/.batch"; K=0` placed as the UNKNOWN arm's first statement leaves the suite fully GREEN).
# Every other assertion about the unmet path is a text pin, and a text pin cannot see what the arm
# DOES. Here the SHIPPED reporting block is extracted and run against fixtures, with the real floor
# helpers and a stub `queue_state_token`; the property asserted is the one the issue states — an
# unmet floor LOGS, and the work already selected is still dispatched.
BLOCK="$T/unmetblock.sh"
awk '/^    # ⛔ AN UNMET FLOOR LOGS AND DEGRADES/ {f=1} f {print} f && /^    fi$/ {exit}' "$LOOP" > "$BLOCK.raw"
grep -q 'product-floor' "$BLOCK.raw"
ck "P10 (setup) the unmet reporting block extracts from the shipped loop" $?
{
  sed -n '/^floor_norm() {/,/^}/p' "$LOOP"
  sed -n '/^floor_order() {/,/^}/p' "$LOOP"
  sed -n '/^floor_choose_order() {/,/^}/p' "$LOOP"
  printf 'queue_state_token() { printf "READ(3)"; }\n'
  cat "$BLOCK.raw"
} > "$BLOCK"
runblock() { # <O> [batch rows] — the state the block inherits from the dispatch loop
  (
    O="$1"; LOG="$1/log"; BATCH=2; K=2
    : > "$LOG"
    # The daemon computes FLOOR_N just before this block; an EMPTY value reads 0 and the whole block
    # is skipped, which looked exactly like "the arm says nothing" when this was first wired.
    FLOOR_N="$(floor_norm 1 2)"
    # `%b`, not `%s`: the optional argument carries its own newlines, which `%s` would print literally.
    printf '%b' "${2:-42\n43\n}" > "$O/.batch"
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
ck "P10 [RED→GREEN] NO product queue: the batch and K SURVIVE (a floor is not a gate) — got '$OUTA'" $A1
case "$OUTA" in *"product class UNKNOWN"*"queue=READ(3)"*) A2=0 ;; *) A2=1 ;; esac
ck "P10 [RED→GREEN] ... and the arm says UNKNOWN with the queue token (got '$OUTA')" $A2
# (b) a product queue holding something not in this batch: the MEASURED arm.
mkdir -p "$T/o9b/state"; printf '42\n43\n' > "$T/o9b/candidates.txt"; printf '99\n' > "$T/o9b/candidates.product.txt"
printf 'OK product=1 harness=0\n' > "$T/o9b/state/product-class"
OUTB="$(runblock "$T/o9b")"
case "$OUTB" in *"BATCH=[42 43]"*"K=[2]"*) A3=0 ;; *) A3=1 ;; esac
ck "P10 [RED→GREEN] a product queue with NO dispatchable match: the batch still dispatches — got '$OUTB'" $A3
case "$OUTB" in *"no dispatchable product candidate"*"queue=READ(3)"*) A4=0 ;; *) A4=1 ;; esac
ck "P10 [RED→GREEN] ... and THAT arm reports the MEASURED absence (got '$OUTB')" $A4
# (c) a repo the refresh RECORDED as not a product repo: N/A, and still dispatched.
mkdir -p "$T/o9c/state"; printf '42\n43\n' > "$T/o9c/candidates.txt"
printf 'NOT-A-PRODUCT-REPO vendor/harness is not in PRODUCT_REPOS (daniel-ospina/tortoise)\n' > "$T/o9c/state/product-class"
OUTC="$(runblock "$T/o9c")"
case "$OUTC" in *"BATCH=[42 43]"*"K=[2]"*) A5=0 ;; *) A5=1 ;; esac
ck "P10 [RED→GREEN] an N/A class does not touch the batch either — got '$OUTC'" $A5
case "$OUTC" in *"product-floor N/A"*) A6=0 ;; *) A6=1 ;; esac
ck "P10 [RED→GREEN] ... and it reports N/A rather than an unmet floor (got '$OUTC')" $A6
# (d) a class the refresh could not read: UNKNOWN, repeating the RECORDED reason instead of re-asking.
mkdir -p "$T/o9d/state"; printf '42\n43\n' > "$T/o9d/candidates.txt"
printf 'BUDGET-SKIPPED the pass had no core budget left\n' > "$T/o9d/state/product-class"
OUTD="$(runblock "$T/o9d")"
case "$OUTD" in *"reason=BUDGET-SKIPPED"*) A7=0 ;; *) A7=1 ;; esac
ck "P10 [RED→GREEN] the UNKNOWN arm repeats the RECORDED reason instead of asking (got '$OUTD')" $A7
# (e) the split RAN and MEASURED zero product candidates: the queue is empty but the class is KNOWN.
# ⛔ WITHOUT THIS ARM THE OK* BRANCH IS NEVER EXECUTED (measured: a `: > "$O/.batch"; K=0` opening it
# left every assertion GREEN) — a MEASURED-empty read is exactly the routine all-harness pass a
# product repo sees every day, so it is the branch most likely to be edited and the last one tested.
mkdir -p "$T/o9e/state"; printf '42\n43\n' > "$T/o9e/candidates.txt"
printf 'OK product=0 harness=3\n' > "$T/o9e/state/product-class"
OUTE="$(runblock "$T/o9e")"
case "$OUTE" in *"BATCH=[42 43]"*"K=[2]"*) A8=0 ;; *) A8=1 ;; esac
ck "P10 [RED→GREEN] a MEASURED-empty queue leaves the batch intact too — got '$OUTE'" $A8
case "$OUTE" in *"split RAN and found none"*"OK product=0 harness=3"*) A9=0 ;; *) A9=1 ;; esac
ck "P10 [RED→GREEN] ... and the OK* arm reports the MEASUREMENT it was given (got '$OUTE')" $A9
case "$OUTE" in *"UNKNOWN"*) A10=1 ;; *) A10=0 ;; esac
ck "P10 [RED→GREEN] ... and it does NOT call a measured zero an UNKNOWN class (got '$OUTE')" $A10

# (f) a batch that DOES contain a product candidate: the indicator's POSITIVE direction.
# ⛔ WITHOUT THIS ARM `PB` HAS NO MET CASE (review cycle 3, P1): only the unmet arms were driven, so
# freezing the counter (`&& PB=$PB`) left every gate green while a satisfied floor was reported as
# unmet on every cycle — the routine line printed in the same words as the real failure, which is the
# masking this whole block exists to remove.
mkdir -p "$T/o9f/state"; printf '12\n34\n56\n' > "$T/o9f/candidates.txt"
printf '34\n56\n' > "$T/o9f/candidates.product.txt"; printf 'OK product=2 harness=1\n' > "$T/o9f/state/product-class"
OUTF9="$(runblock "$T/o9f" "$(printf '34\n12\n')")"
case "$OUTF9" in *"product=1/2 in this batch (floor=1)"*) F1=0 ;; *) F1=1 ;; esac
ck "P10 [RED→GREEN] a batch CONTAINING a product candidate reports product=1/2 — got '$OUTF9'" $F1
case "$OUTF9" in *"floor unmet"*) F2=1 ;; *) F2=0 ;; esac
ck "P10 [RED→GREEN] ... and does NOT claim the floor is unmet (got '$OUTF9')" $F2

echo
echo "── P11: the two WIRES that make the floor reachable, and the flag that makes it safe ─────"
# ⛔ A FUNCTION NOBODY CALLS IS NOT A FEATURE (review cycle 3, P1). `write_product_queues` was extracted
# and driven by P7 — which proves the function, and proves NOTHING about whether the daemon ever calls
# it. Measured: deleting the single call site in `refresh-candidates.sh` left this suite at 71/0 and
# refresh-scout at 284/0, i.e. the floor's entire intake could be removed with every gate green, and
# every cycle would then print `unmet … UNKNOWN`. The pins are ANCHORED to code lines, because the
# plain `grep 'candidates.product.txt'` they replace is satisfied by the comments naming the file.
grep -Eq '^[[:space:]]*write_product_queues "\$O" "\$OR"' "$REFRESH"
ck "P11 [RED→GREEN] the refresh pass CALLS write_product_queues (the wire, not just the definition)" $?
# ⛔ AND THE SATURATION FLAG HAS A PRODUCER (review cycle 3, P1). P7's truncation arm sets
# `REST_WINDOW_FILLED` in its own `rest_list` stub, so it proves the CONSUMER against a hand-set flag;
# the only thing that can set that flag in production is two lines in the shipped `rest_list`, and
# nothing read them. Measured: deleting both left 71/0 and 284/0 — the saturation guard permanently
# dead, in the one direction the design forbids (an unseen harness row classified PRODUCT).
RLF="$T/rest-list.sh"
sed -n '/^rest_list() {/,/^}/p' "$REFRESH" > "$RLF"
[ -s "$RLF" ] && grep -q 'REST_WINDOW_FILLED' "$RLF"
ck "P11 (setup) the shipped rest_list extracts and mentions the saturation flag" $?
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
    # shellcheck source=/dev/null
    . "$RLF" || exit 1
    rest_list issues --repo "daniel-ospina/tortoise" --limit 100 >/dev/null 2>&1 || :
    printf 'FILLED=%s\n' "${REST_WINDOW_FILLED:-unset}"
  ) 2>&1
}
SATP="$(runrest 100 1)"
case "$SATP" in *FILLED=1*) S1=0 ;; *) S1=1 ;; esac
ck "P11 [RED→GREEN] the SHIPPED rest_list SETS the flag when the window fills with a next page advertised — got '$SATP'" $S1
SATN="$(runrest 40 0)"
case "$SATN" in *FILLED=0*) S2=0 ;; *) S2=1 ;; esac
ck "P11 [RED→GREEN] ... and leaves it CLEAR for a short final page with no next page — got '$SATN'" $S2

echo
echo "═══════════════════════════════════════════════"
echo "   $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '%s' "$FAILED_LINES" | sed 's/^/  failed: /'
  exit 1
fi
