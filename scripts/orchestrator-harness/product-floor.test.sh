#!/usr/bin/env bash
# product-floor.test.sh — the PRODUCT WORK FLOOR (agent-infra#2054).
#
# ⛔ THE FAILURE THIS PREVENTS. The fleet's mix being fine TODAY is not a guarantee: harness work has a
# dispatch path that bypasses prioritisation (`bg/nonblocking-dispatch.sh` spawns workers directly — no
# pool, no pre-flight, no tier, no lane accounting) while the product channel goes through the queue. So
# the product share is guaranteed by NOTHING, and the day the queue drains into harness work the fleet
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
  sed -n '/^floor_split() {/,/^}/p' "$LOOP"
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
# ⛔ ANCHORED TO THE ECHO ITSELF (cycle-2 review, P1): a bare `grep 'product-floor unmet'` was
# satisfied by orch-loop.sh's own COMMENT explaining what the line is for, and a bare
# `grep 'queue=$(queue_state_token)'` by ~20 unrelated call sites — deleting BOTH unmet lines and
# stripping the token from them still measured 38/39. Each arm is now pinned as an echo line whose
# message AND token are on that line.
grep -Eq '^[[:space:]]*echo "\[dispatch\] product-floor unmet \(no dispatchable product candidate\) queue=\$\(queue_state_token\)' "$LOOP"
ck "P6 [RED→GREEN] the MEASURED unmet arm is an echo that carries the queue-state token" $?
grep -Eq '^[[:space:]]*echo "\[dispatch\] product-floor unmet \(product class UNKNOWN' "$LOOP" \
  && grep -Eq 'queue=\$\(queue_state_token\)' "$LOOP"
ck "P6 [RED→GREEN] the UNKNOWN arm exists and carries the queue-state token too" $?
# An unmet floor must not close the lane: the same branch must still reach the batch dispatch.
grep -q 'product-floor unmet' "$LOOP" && ! grep -q 'exit .*product-floor' "$LOOP"
ck "P6 [RED→GREEN] an unmet floor NEVER refuses the batch (no exit on the unmet path)" $?
# ⛔ AND IT MAY NOT EMPTY THE BATCH EITHER (cycle-1 review, P1): "log and degrade" means the issues this
# pass already selected are still dispatched. The failure to exclude is `: > "$O/.batch"; K=0` on the
# unmet path — dispatch then stalls until a product candidate appears, which is exactly the
# don't-cap-the-fleet rule the issue states. A spelling pin, stated as one: the unmet arms contain no
# batch-truncation or counter reset.
# ⛔ THE WINDOW IS THE TWO UNMET ARMS, FOUND BY THEIR ECHO LINES (cycle-2 review, P1). The first
# version opened the window at the first line CONTAINING "product-floor unmet" — which is a comment
# ABOVE the code — and closed at the next `fi`, so it covered one arm and missed the `elif` arm that
# fires whenever the product queue is absent or empty, i.e. the NORMAL unmet case: `: > "$O/.batch"; K=0`
# as that arm's first statement left 39/39 green. The property is driven for real in P9 now; this stays
# as a cheap secondary, anchored after each echo.
awk '/^[[:space:]]*echo "\[dispatch\] product-floor unmet/{f=1;next} f&&/^[[:space:]]*fi[[:space:]]*$/{f=0} f&&(/: > "\$O\/\.batch"/||/^[[:space:]]*K=0/) {print "TRUNCATES"; exit}' "$LOOP" | grep -q TRUNCATES
P6_TRUNC=$?
[ "$P6_TRUNC" -ne 0 ]
ck "P6 [RED→GREEN] neither unmet arm truncates the batch or resets K (a floor is not a gate)" $?
# The UNKNOWN arm must not claim an absence it did not measure (the #2042/#1931 masking shape).
awk '/candidates.product.txt is absent or empty/{print}' "$LOOP" | grep -q 'product class UNKNOWN'
ck "P6 [RED→GREEN] the unreadable-class arm says UNKNOWN, not 'no product candidate'" $?

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
# ⛔ ANCHORED TO THE CONSUMPTION, NOT TO THE NAME (cycle-2 review, P1): `grep -q PRODUCT_FLOOR` was
# satisfied by the comments, so replacing the shipped `FLOOR_N="$(floor_norm …)"` with `FLOOR_N=1` made
# the plist/README tunable a DEAD KNOB and left 39/39 green.
grep -Eq '^[[:space:]]*FLOOR_N="\$\(floor_norm "\$\{PRODUCT_FLOOR:-1\}" "\$\{BATCH:-1\}"\)"' "$LOOP"
ck "P7 [RED→GREEN] the loop CONSUMES PRODUCT_FLOOR (floor_norm reads the tunable, not a literal)" $?
grep -Eq '^[[:space:]]*PRODUCT_FLOOR="\$\{PRODUCT_FLOOR:-1\}"' "$LOOP"
ck "P7 [RED→GREEN] ... and its documented default is 1 (a floor defaulting to 0 is off and green)" $?
# ⛔ AND THE REFRESH'S SPLIT IS DRIVEN, NOT GREPPED (cycle-1 review, P1). Two defects survived the
# grep-only version: the inline block called `floor_split`, which lives in orch-loop.sh — the refresh
# runs as a CHILD process and never sources it, so the operator's line printed NO COUNTS on every pass
# under `2>/dev/null`; and the failed-listing polarity (a read that did not answer must classify
# everything as HARNESS, never manufacture product work) had no assertion at all, so inverting it left
# the suite green. `write_product_queues` is extracted from the shipped refresh and driven here, both
# arms, with a stubbed `rest_list`.
WFNS="$T/wfns.sh"
sed -n '/^write_product_queues() {/,/^}/p' "$REFRESH" > "$WFNS"
[ -s "$WFNS" ] && grep -q 'write_product_queues()' "$WFNS"
ck "P7 (setup) the refresh's split function extracts from the shipped file" $?
wk() { # <O> <OR> <PRODUCT_REPOS> <rest_list-rc> [harness-list]
  local o="$1" repo="$2" pre="$3" rc="$4" lst="${5:-}"
  (
    O="$o"; CORE_NOW=""; CORE_RESERVE=""
    rest_list() { [ "$rc" = "0" ] || return 1; printf '%s\n' $lst; }
    # shellcheck source=/dev/null
    . "$WFNS" || exit 1
    write_product_queues "$o" "$repo" "$pre"
  ) 2>&1
}
mkdir -p "$T/wo"; printf '12\n34\n56\n' > "$T/wo/candidates.txt"
# ⛔ THE LISTING CONTAINS A NUMBER THAT IS NOT IN THE BACKLOG (78), so "harness = the COMPLEMENT of
# product" cannot be confused with "harness = whatever the --label harness listing said" (cycle-2
# review, P2): with the old fixture the listing happened to EQUAL the complement, and substituting
# `cp "$o/.harness-issues" "$o/candidates.harness.txt"` stayed green.
OUTW="$(wk "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise 0 "12 56 78")"
PRODW="$(tr '\n' ' ' < "$T/wo/candidates.product.txt" | sed 's/ $//')"
HARNW="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" | sed 's/ $//')"
[ "$PRODW" = "34" ] && [ "$HARNW" = "12 56" ]
ck "P7 [RED→GREEN] a SUCCESSFUL label listing splits the backlog: product='$PRODW' harness='$HARNW'" $?
case "$OUTW" in *"split: product 1 harness 2"*) W1=0 ;; *) W1=1 ;; esac
ck "P7 [RED→GREEN] the split line CARRIES ITS COUNTS (got '$OUTW')" $W1
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
# ⛔ THE BUDGET ARM IS DRIVEN TOO (cycle-2 review, P1): there are THREE degrade paths, and the
# comment claimed the test drove "both arms". This one is the pass that cannot afford the listing — it
# must produce an EMPTY product queue, the full backlog as harness, and a reason that names the budget.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTB="$(
  O="$T/wo"; CORE_NOW=3; CORE_RESERVE=2
  rest_list() { printf '%s\n' 12 56; }
  . "$WFNS" || exit 1
  write_product_queues "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise
) 2>&1"
PRODB="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
HARNB="$(tr '\n' ' ' < "$T/wo/candidates.harness.txt" | sed 's/ $//')"
[ "$PRODB" = "0" ] && [ "$HARNB" = "12 34 56" ]
ck "P7 [RED→GREEN] a pass that cannot AFFORD the listing degrades: product=$PRODB harness='$HARNB'" $?
case "$OUTB" in *"budget"*) W4=0 ;; *) W4=1 ;; esac
ck "P7 [RED→GREEN] ... and names the budget as the reason (got '$OUTB')" $W4
# ⛔ A SATURATED WINDOW IS NOT A COMPLETE ANSWER, and the polarity matters: at the 500-row bound the
# listing is TRUNCATED, and every harness-labelled issue past it would be classified PRODUCT — the
# exact inversion this function exists to prevent. It degrades instead, and says which it was.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTS="$(
  O="$T/wo"; CORE_NOW=""; CORE_RESERVE=""
  rest_list() { seq 1 500; }
  . "$WFNS" || exit 1
  write_product_queues "$T/wo" daniel-ospina/tortoise daniel-ospina/tortoise
) 2>&1"
PRODS="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PRODS" = "0" ]
ck "P7 [RED→GREEN] a SATURATED (500-row) label listing degrades instead of inventing product (product=$PRODS)" $?
case "$OUTS" in *TRUNCATED*) W5=0 ;; *) W5=1 ;; esac
ck "P7 [RED→GREEN] ... and says the window was truncated (got '$OUTS')" $W5

# A repo outside PRODUCT_REPOS is all-harness by definition, and costs NO call at all.
printf '12\n34\n56\n' > "$T/wo/candidates.txt"
OUTR="$(wk "$T/wo" daniel-ospina/agent-infra daniel-ospina/tortoise 0 "12 56")"
PRODR="$(wc -l < "$T/wo/candidates.product.txt" | tr -d ' ')"
[ "$PRODR" = "0" ]
ck "P7 [RED→GREEN] a repo OUTSIDE PRODUCT_REPOS is all-harness (product=$PRODR)" $?
case "$OUTR" in *"not in PRODUCT_REPOS"*) W3=0 ;; *) W3=1 ;; esac
ck "P7 [RED→GREEN] ... and names the knob that decides it (got '$OUTR')" $W3

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
echo "── P9: the UNMET block is EXECUTED, and it leaves the batch intact ────────────────────────"
# ⛔ NO SUITE RAN THIS BLOCK (cycle-2 review, P1). refresh-scout.sh's extraction stops at
# `done < "$ORDER_FILE"`, so every assertion about the unmet path was a text pin — and a text pin with a
# window starting at a COMMENT missed the `elif` arm entirely, which is the arm that fires in the NORMAL
# unmet case (no product queue at all). Here the SHIPPED block is extracted and run, twice, with the real
# `floor_norm`/`floor_choose_order` and a stub `queue_state_token`; the property asserted is the one the
# issue states: an unmet floor LOGS and the work already selected is still dispatched.
BLOCK="$T/unmetblock.sh"
# ⛔ THE REPORTING BLOCK ONLY, NOT THE DISPATCH LOOP (measured): extracting from the floor's opening
# comment also carried the `while` loop, so the fixture dispatched an issue and read K=3 — a fixture bug
# that would have blamed the code. The reporting block starts at its own marker comment and ends at the
# FIRST 4-space `fi` (the inner `if`/`elif` close deeper).
awk '/^    # ⛔ AN UNMET FLOOR LOGS AND DEGRADES/ {f=1} f {print} f && /^    fi$/ {exit}' "$LOOP" > "$BLOCK.raw"
{
  sed -n '/^floor_norm() {/,/^}/p' "$LOOP"
  sed -n '/^floor_order() {/,/^}/p' "$LOOP"
  sed -n '/^floor_choose_order() {/,/^}/p' "$LOOP"
  printf 'queue_state_token() { printf "READ(3)"; }\n'
  cat "$BLOCK.raw"
} > "$BLOCK"
grep -q 'product-floor unmet' "$BLOCK"
ck "P9 (setup) the unmet reporting block extracts from the shipped loop" $?
runblock() { # <O> — run the block with a filled batch of 2
  (
    O="$1"; LOG="$1/log"; BATCH=2; K=2
    : > "$LOG"
    # The daemon computes FLOOR_N just before this block; an EMPTY value here reads 0 and the block is
    # skipped entirely — which is what the first fixture did, and it looked like the arm said nothing.
    FLOOR_N="$(floor_norm 1 2)"
    printf '42\n43\n' > "$O/.batch"
    # shellcheck source=/dev/null
    . "$BLOCK" || exit 1
    # The block reports through `>> "$LOG"`, so the fixture reads the log it wrote — not stdout, which
    # is where a first version looked and then claimed the arm said nothing (measured).
    printf 'BATCH=[%s] K=[%s] LOG=[%s]\n' "$(tr '\n' ' ' < "$O/.batch" | sed 's/ $//')" "$K" \
      "$(tr '\n' ' ' < "$O/log" 2>/dev/null | sed 's/ *$//')"
  ) 2>&1
}
mkdir -p "$T/o9a"; printf '42\n43\n' > "$T/o9a/candidates.txt"
OUTA="$(runblock "$T/o9a")"
case "$OUTA" in *"BATCH=[42 43]"*"K=[2]"*) A1=0 ;; *) A1=1 ;; esac
ck "P9 [RED→GREEN] NO product queue: the batch and K SURVIVE (a floor is not a gate) — got '$OUTA'" $A1
case "$OUTA" in *"product class UNKNOWN"*"queue=READ(3)"*) A2=0 ;; *) A2=1 ;; esac
ck "P9 [RED→GREEN] ... and the arm says UNKNOWN with the queue token (got '$OUTA')" $A2
mkdir -p "$T/o9b"; printf '42\n43\n' > "$T/o9b/candidates.txt"; printf '99\n' > "$T/o9b/candidates.product.txt"
OUTB="$(runblock "$T/o9b")"
case "$OUTB" in *"BATCH=[42 43]"*"K=[2]"*) A3=0 ;; *) A3=1 ;; esac
ck "P9 [RED→GREEN] a product queue with NO dispatchable match: the batch still dispatches — got '$OUTB'" $A3
case "$OUTB" in *"no dispatchable product candidate"*"queue=READ(3)"*) A4=0 ;; *) A4=1 ;; esac
ck "P9 [RED→GREEN] ... and THAT arm reports the MEASURED absence (got '$OUTB')" $A4

echo
echo "═══════════════════════════════════════════════"
echo "   $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '%s' "$FAILED_LINES" | sed 's/^/  failed: /'
  exit 1
fi
