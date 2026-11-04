#!/usr/bin/env bash
# rank-queue.test.sh — the regression contract for the QUEUE'S ORDER (agent-infra#2019, PR #3234).
#
# THE DEFECT, IN ONE SENTENCE. `candidates.txt` is the file `orch-loop.sh` walks TOP-DOWN, so its head
# IS the dispatch order — and it was in ARRIVAL order: the pool's `P0-blocker`/`P1-severe`/`P2-moderate`
# ladder ordered only the STREAM new candidates were appended in, never the queue itself, so the head was
# the OLDEST clean entry. MEASURED on the live controller 2026-11-01: queue depth 179, head `#2944`
# (`P2-moderate`), while the pool's first eleven rows were the `P0-blocker` tier; the issues the cycle
# actually dispatched (#2567, #2653, #2683, #2927) ALL carry `P2-moderate` and NONE carries
# `P0-blocker`/`P1-severe`. The pass said so itself, verbatim: `[refresh] handed to dispatch: #2567 —
# carried over from an earlier pass — the oldest CLEAN entry still queued`.
#
# WHICH IS WHY THIS SUITE EXISTS AT ALL. The change that fixes it (`rank_queue_by_pool` +
# `queue_order_from_pool`) is ~90 lines of awk that rewrites a LIVE queue every pass, and when it was
# first opened NOTHING asserted it: the only self-test that drives this file's queue-write region
# (`selftest.sh` check 18) extracted its fragment from a point BELOW both definitions, so its call site
# executed as `command not found` — swallowed by `|| true` — and the check stayed green while asserting,
# in its own name, that *"nothing running it re-sorts it"*. The shipped behaviour and the guard's claim
# had inverted, and nothing reddened. That is a false-PASS guard (agent-infra's own category A).
#
# WHAT THIS SUITE PINS, and why each one is a BEHAVIOUR rather than a spelling:
#   1. ORDER is the pool's rank — not issue number, not arrival. A regression that sorts numerically
#      still "orders" and still starves the P0s (#8465 itself).
#   2. MEMBERSHIP is preserved — order only. Every DISTINCT queued row survives, and a row the pool does
#      not rank sits at the TAIL in its existing order. Dropping it would silently discard a
#      CLEAN-judged candidate, which is the failure "order, never membership" exists to forbid.
#   3. A queue the pool ranks NOTHING is `priority-unreadable`, never arrival order read as severity —
#      the silent degradation that produced the measured beat.
#   4. An EMPTY queue is a neutral success in its own words, never the failure word (`priority-unreadable`
#      over a fully drained queue — the routine state after a good pass — would be a false alarm).
#   5. A reorder that FAILS leaves the file byte-identical AND names itself, so a failed write can never
#      read as an ordered queue — and it may NOT name an order it did not read. The failure arms leave the
#      file UNTOUCHED (`rm -f`, no `mv`), so it holds whatever the PREVIOUS pass left; "is in ARRIVAL
#      order" was a typed claim about an unread file, and is asserted ABSENT here while assertion 3 (the
#      arm that really does rewrite in arrival order) asserts it PRESENT, so the pair discriminates.
#   6. The WIRING: both call sites exist and both follow the definitions, so the reorder cannot go inert
#      the way the first cut of this change did (defined after the skip arm's call site, line ~1337
#      apart — `command not found`, absorbed).
#
# HOW THE CHECKS ARE WRITTEN. Every check drives the SHIPPED functions, extracted from
# `refresh-candidates.sh` itself — never a re-implementation, which would pass just as well on the
# broken copy. Two rules keep a check from passing for the wrong reason (both learned from this repo's
# own review cycles): an ABSENCE assertion is always paired with a POSITIVE one in the same check, so a
# driven block that silently does nothing reads RED rather than green; and NON-VACUITY is proven by
# MUTATION — each invariant below is also run against a source that lacks it (the pre-fix baseline, and
# a tail dropped from the awk), and the check must go RED there. A guard whose red path has never been
# executed is an assertion about a fixture, not about the shipped code.
#
# No network, no gh, no controller: the functions touch one directory of plain files.
#
# Run:  bash scripts/orchestrator-harness/rank-queue.test.sh
# (No `# shard:` line: the marker is read from the first 20 lines ONLY, so one down here is inert, and
#  moved into the header it would be an UNRECOGNISED marker — run-bash-shards.sh:236 refuses the whole
#  run on it. This suite has no opt-out to declare; shard_discover runs an unmarked suite by default.)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH="$HERE/refresh-candidates.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
ck()  { # ck <name> <0|1> — the shared vocabulary the sibling suites use
  if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi
}

# ── TOOL PREFLIGHT ────────────────────────────────────────────────────────────
# A suite that cannot get the code under test must never report green. Fail ONCE, by name, instead of
# leaving 10 cryptic assertion failures that read as "the reorder is broken".
MISSING=""
for t in awk sed grep sort cksum mktemp wc tr; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
if [ -n "$MISSING" ]; then
  echo "❌ SKIP-CANNOT-RUN: missing tool(s):$MISSING — this suite cannot grade the shipped code" >&2
  exit 1
fi
if [ ! -s "$REFRESH" ]; then
  echo "❌ SKIP-CANNOT-RUN: $REFRESH is missing or empty — this suite cannot grade the shipped code" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/rank-queue.XXXXXX")" || { echo "❌ SKIP-CANNOT-RUN: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── EXTRACT THE SHIPPED FUNCTIONS ─────────────────────────────────────────────
# Start at `rank_queue_by_pool() {` and stop at the comment that opens the block AFTER
# `queue_order_from_pool` — the two functions are contiguous and both precede it. Anchoring on a
# TERMINATOR is deliberate: an anchor that only found the START would silently capture the rest of the
# file, and a drive of half the script under `set -u` fails for reasons unrelated to this contract.
FNS="$TMP/fns.sh"
awk '/^rank_queue_by_pool\(\) \{/{f=1} f && /^# The previous pass.s record/{exit} f' "$REFRESH" > "$FNS"
if [ -s "$FNS" ] \
   && grep -q '^rank_queue_by_pool() {' "$FNS" \
   && grep -q '^queue_order_from_pool() {' "$FNS" \
   && [ "$(tail -1 "$FNS" | tr -d ' ')" = "}" ]; then
  fns_shape=0
else
  fns_shape=1
fi
ck "the two queue-order functions are extracted WHOLE from the shipped script (start and terminator both found)" $fns_shape
# Fail closed from here if the extraction is not whole: every check below would be meaningless.
if [ "$fns_shape" -ne 0 ]; then
  echo "── rank-queue: $PASS passed, $FAIL failed"
  exit 1
fi

# ── THE DRIVE ─────────────────────────────────────────────────────────────────
# drive <label> <source> <queue-lines> <pool-lines|-> [call|nocall]
#   writes <TMP>/<label>/{o/candidates.txt,o/.pool}, builds a driver from <source> (the shipped
#   functions, or a MUTATED copy of them) plus the one call, runs it, and leaves:
#     $D/out  — stdout+stderr of the run
#     $D/order — candidates.txt afterwards, space-joined
#     $D/rc   — the run's exit status
#   `nocall` runs the functions WITHOUT the call: the PRE-FIX baseline (arrival order), which is how a
#   mutation check proves the assertion can fail at all.
drive() {
  local label="$1" src="$2" q="$3" pool="$4" how="${5:-call}"
  local d="$TMP/$label"
  mkdir -p "$d/o" || return 1
  printf '%s' "$q" > "$d/o/candidates.txt" || return 1
  [ "$pool" = "-" ] || printf '%s' "$pool" > "$d/o/.pool" || return 1
  {
    echo 'QUEUE_ORDER_STATE=""'
    cat "$src"
    [ "$how" = "call" ] && printf 'queue_order_from_pool "$1"\n'
    printf 'exit 0\n'
  } > "$d/drive.sh" || return 1
  # Sandboxed twice over: the only path handed in is $d/o, and HOME points inside $d, so a path spelled
  # any other way still cannot reach a live controller's ~/orchestrator.
  ( cd "$d" && HOME="$d" bash drive.sh "$d/o" ) > "$d/out" 2>&1
  echo "$?" > "$d/rc"
  tr '\n' ' ' < "$d/o/candidates.txt" 2>/dev/null | sed 's/ *$//' > "$d/order"
  return 0
}

# ── 1) ORDER IS THE POOL'S RANK — not issue number, not arrival ───────────────
# Queue arrives `300 9 200` (arrival), pool ranks `200` then `300`. Expected `200 300 9`: the pool's
# line order IS the rank, so there is no second sort key and no second priority predicate (#1178).
# A numeric sort would give `9 200 300`; arrival order would give `300 9 200` — three distinct answers.
drive rank "$FNS" '300
9
200
' '200
300
'
got="$(cat "$TMP/rank/order" 2>/dev/null)"
[ "$got" = "200 300 9" ] && rc=0 || { rc=1; echo "      got '$got' (want '200 300 9')"; }
ck "queue order is the POOL's rank (pool '200,300' over queue '300,9,200' -> '200 300 9', not numeric, not arrival)" $rc

# 1b) NON-VACUITY of the check above: the SAME fixture with the call REMOVED (the pre-fix baseline) must
#     NOT produce the expected order. Without this, a drive that silently does nothing would pass.
drive rank-prefix "$FNS" '300
9
200
' '200
300
' nocall
pre="$(cat "$TMP/rank-prefix/order" 2>/dev/null)"
[ -n "$pre" ] && [ "$pre" != "200 300 9" ] && rc=0 || { rc=1; echo "      pre-fix baseline gave '$pre' — the assertion above cannot discriminate"; }
ck "non-vacuity: the pre-fix baseline (arrival order) does NOT satisfy the rank assertion" $rc

# 1c) NON-VACUITY by MUTATION: drop the unranked-tail emit from the awk and confirm the ORDER checks
#     redden on it. A guard whose red path has never run is an assertion about a fixture.
#     ⛔ AND THE MEMBERSHIP GUARD IS WHAT NOW CATCHES IT (review P1, cycle 4): the tail-dropping awk no
#     longer emits the same ROW SET, so `rank_queue_by_pool` REFUSES the install — the queue is left
#     BYTE-IDENTICAL and the pass says `priority-unreadable`. That is a STRONGER outcome than the old
#     assertion ("the mutated order lands, minus the tail"), and it is what must be pinned: a mutation
#     that silently discards a row must be UNINSTALLABLE, not merely visible.
MUT_DROP_TAIL="$TMP/fns-drop-tail.sh"
sed 's/{ print n; unranked++ }/{ unranked++ }/' "$FNS" > "$MUT_DROP_TAIL"
grep -q 'print n; unranked++' "$MUT_DROP_TAIL" && mutated=1 || mutated=0
[ "$mutated" -eq 0 ] && rc=0 || { rc=1; echo "      the mutation did not apply — sed anchor drifted"; }
ck "the tail-dropping mutation applied to the extracted awk (its anchor still matches the source)" $rc
drive mut-droptail "$MUT_DROP_TAIL" '300
9
200
' '200
300
'
mut="$(cat "$TMP/mut-droptail/order" 2>/dev/null)"
if [ "$mut" = "300 9 200" ] && grep -q 'priority-unreadable' "$TMP/mut-droptail/out" 2>/dev/null; then rc=0
else rc=1; echo "      mutated source gave '$mut' (want the queue UNTOUCHED, '300 9 200'); out: $(tr '\n' '|' < "$TMP/mut-droptail/out" 2>/dev/null | head -c 240)"; fi
ck "mutation is LIVE and UNINSTALLABLE: a tail-dropping reorder refuses to install, leaving the queue untouched" $rc

# ── 2) MEMBERSHIP IS PRESERVED — order only, and a duplicate is not a distinct row ──
# The queue carries a DUPLICATE 5000, which the pre-existing `awk !seen` dedupe already collapses. The
# invariant is: no DISTINCT row is added or dropped, so the sorted set before and after is identical.
drive member "$FNS" '5000
100
9000
5000
' '100
'
before_set="$(printf '5000\n100\n9000\n5000\n' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//')"
after_set="$(sort -n "$TMP/member/o/candidates.txt" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ *$//')"
[ "$after_set" = "$before_set" ] && rc=0 || { rc=1; echo "      before-set '$before_set' != after-set '$after_set'"; }
ck "membership preserved as a SET: pool '100' over queue '5000,100,9000,5000' keeps every distinct row (5000 9000 100)" $rc
got="$(cat "$TMP/member/order" 2>/dev/null)"
[ "$got" = "100 5000 9000" ] && rc=0 || { rc=1; echo "      order '$got' (want '100 5000 9000')"; }
ck "the ranked row leads, the unranked rows follow in their EXISTING order (100 5000 9000)" $rc

# 2b) NON-VACUITY of the membership guard: the condition it refuses on must be REACHABLE, not
#     hypothetical. The guard now lives at the INSTALL (cycle 5), so a differing row set can no longer
#     be installed at all — which means the proof belongs one layer down: drive the RANKER directly
#     with the tail-dropping mutation and show its output's ROW SET really is missing a row. If this
#     ever equals the queue's set, the mutation has gone inert and 1c's refusal proves nothing.
DR="$TMP/mut-member"; mkdir -p "$DR"
printf '5000\n100\n9000\n5000\n' > "$DR/q"
printf '100\n' > "$DR/pool"
{
  cat "$MUT_DROP_TAIL"
  printf 'rank_queue_by_pool "$1" "$2" "$3" "$4"\nexit $?\n'
} > "$DR/drive.sh"
( cd "$DR" && HOME="$DR" bash drive.sh "$DR/pool" "$DR/q" "$DR/out" "$DR/cnt" ) >/dev/null 2>&1
mut_set="$(sort -n "$DR/out" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ *$//')"
[ -n "$mut_set" ] && [ "$mut_set" != "$before_set" ] && rc=0 || { rc=1; echo "      mutated ranker emitted '$mut_set' (queue set '$before_set') — the tail-dropping mutation is inert, so 1c proves nothing"; }
ck "non-vacuity: the tail-dropping ranker's ROW SET really does differ from the queue's (the condition the install refuses on)" $rc

# ── 3) THE UNRANKED TAIL KEEPS ITS OWN RELATIVE ORDER ────────────────────────
# Two ranked rows (200, 300) and two unranked (9, 7) INTERLEAVED in the queue: the tail must come out in
# the order the queue had them (9 then 7), not reversed and not numerically sorted.
drive tail "$FNS" '9
300
7
200
' '200
300
'
got="$(cat "$TMP/tail/order" 2>/dev/null)"
[ "$got" = "200 300 9 7" ] && rc=0 || { rc=1; echo "      got '$got' (want '200 300 9 7')"; }
ck "unranked rows sit at the TAIL in their existing relative order (pool '200,300' over '9,300,7,200' -> '200 300 9 7')" $rc

# ── 4) A POOL THAT RANKS NOTHING IS `priority-unreadable`, NOT ARRIVAL-AS-SEVERITY ──
# The silent degradation: a ladder returning "no priority" for everything reads exactly like a healthy
# FIFO. The file must be left BYTE-IDENTICAL (it is not this function's business to drop what it cannot
# rank) AND the state must be named, and the positive half — the `severity-first` claim — must be ABSENT.
drive norank "$FNS" '300
9
' '777
'
sum_before="$(cksum < "$TMP/norank/o/candidates.txt" 2>/dev/null)"
sum_after="$(printf '300\n9\n' | cksum)"
same=1; [ "$sum_before" = "$sum_after" ] && same=0
# ⛔ AND IT MAY **NOT** NAME "ARRIVAL ORDER" (review P2, cycle 3). It used to, on the premise that "the
# file really was rewritten and the pool ranked nothing in it" — but the rewrite emits the rows in their
# EXISTING order (`qorder`), so the bytes do not move; after an earlier ranking pass that existing order
# IS severity, not arrival. The claim was therefore false in exactly the state a `.pool` that lists
# nothing (routine) lands in, and this suite REQUIRED the false wording. Both halves are asserted here:
# the honest word PRESENT, and `ARRIVAL order` ABSENT.
if [ "$same" -eq 0 ] && grep -q 'priority-unreadable' "$TMP/norank/out" 2>/dev/null \
   && grep -q 'established NO priority order' "$TMP/norank/out" 2>/dev/null \
   && grep -q 'UNTOUCHED' "$TMP/norank/out" 2>/dev/null \
   && ! grep -q 'ARRIVAL order' "$TMP/norank/out" 2>/dev/null \
   && ! grep -q 'severity-first' "$TMP/norank/out" 2>/dev/null; then rc=0
else
  rc=1; echo "      same=$same; out: $(tr '\n' '|' < "$TMP/norank/out" 2>/dev/null | head -c 300)"
fi
ck "a pool ranking NONE of the queue says 'priority-unreadable', leaves the file byte-identical, names NO priority order and NOT 'ARRIVAL order', and never claims severity" $rc

# 4b) POSITIVE PAIR: the same drive with a pool that DOES rank one row must claim severity-first — so the
#     absence asserted above is not just a broken driver printing nothing.
drive ranked "$FNS" '300
9
' '300
'
if grep -q 'severity-first' "$TMP/ranked/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/ranked/out" 2>/dev/null | head -c 300)"; fi
ck "positive pair: a pool that DOES rank a row prints 'severity-first' (the absence above is not vacuous)" $rc

# ── 5) AN EMPTY QUEUE IS A NEUTRAL SUCCESS IN ITS OWN WORDS ───────────────────
# A fully drained queue is the routine state after a good pass. Reporting the failure word over it would
# be a false alarm on the healthiest possible queue.
drive empty "$FNS" '' '200
'
if [ ! -s "$TMP/empty/o/candidates.txt" ] && grep -q 'the queue is EMPTY' "$TMP/empty/out" 2>/dev/null \
   && ! grep -q 'priority-unreadable' "$TMP/empty/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/empty/out" 2>/dev/null | head -c 300)"; fi
ck "an EMPTY queue reports 'the queue is EMPTY' — not the failure word, and the file stays empty" $rc

# ── 6) A FAILED REORDER LEAVES THE QUEUE INTACT AND SAYS SO ──────────────────
# No `.pool` at all: the rank cannot be derived. The queue must stay byte-identical and the state must be
# named — a failed write that silently left arrival order in place is the defect this arm exists for.
drive nopool "$FNS" '300
9
' '-'
sum_before="$(cksum < "$TMP/nopool/o/candidates.txt" 2>/dev/null)"
sum_after="$(printf '300\n9\n' | cksum)"
if [ "$sum_before" = "$sum_after" ] && grep -q 'priority-unreadable' "$TMP/nopool/out" 2>/dev/null \
   && [ ! -e "$TMP/nopool/o/.cand.ranked" ] && [ ! -e "$TMP/nopool/o/.queue-rank" ]; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/nopool/out" 2>/dev/null | head -c 300); leftovers: $(ls -a "$TMP/nopool/o" | tr '\n' ' ')"; fi
ck "an unreadable pool leaves candidates.txt byte-identical, names 'priority-unreadable', and leaves no temp file behind" $rc

# 6a) A FAILED REORDER MAY NOT NAME AN ORDER IT DID NOT READ (review P2, cycle 2). The failure arms leave
#     the file UNTOUCHED, so it still holds whatever the PREVIOUS pass left — after a good pass that is
#     the POOL's order, not arrival order. The first version of the message asserted "is in ARRIVAL
#     order" about a file this pass never read, which is a typed claim where a read one belongs.
if ! grep -q 'ARRIVAL order' "$TMP/nopool/out" 2>/dev/null && grep -q 'UNVERIFIED' "$TMP/nopool/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/nopool/out" 2>/dev/null | head -c 300)"; fi
ck "a FAILED reorder says the queue is UNCHANGED/UNVERIFIED — it does not name 'ARRIVAL order' for a file it never read" $rc

# 6a-bis) AND THE TWO UNREADABLE STATES ARE DISTINGUISHABLE, so the ABSENCES above discriminate rather
#     than being phrases nobody emits (review P2, cycle 3). The FAILED arm says UNVERIFIED and must NOT
#     claim "NO priority order" was established; the ranked-nothing arm says the opposite. One arm's
#     absence is the other's presence, so deleting a phrase from BOTH reds exactly one of them.
drive norank2 "$FNS" '300
9
' '777
'
_rn="$TMP/norank2/out"; _np="$TMP/nopool/out"
if grep -q 'established NO priority order' "$_rn" 2>/dev/null \
   && ! grep -q 'UNVERIFIED' "$_rn" 2>/dev/null \
   && grep -q 'UNVERIFIED' "$_np" 2>/dev/null \
   && ! grep -q 'established NO priority order' "$_np" 2>/dev/null; then rc=0
else rc=1; echo "      ranked-none: NO-order=$(grep -c 'established NO priority order' "$_rn" 2>/dev/null) UNVERIFIED=$(grep -c 'UNVERIFIED' "$_rn" 2>/dev/null); failed: UNVERIFIED=$(grep -c 'UNVERIFIED' "$_np" 2>/dev/null) NO-order=$(grep -c 'established NO priority order' "$_np" 2>/dev/null)"; fi
ck "the two unreadable states are distinguishable: 'failed' says UNVERIFIED, 'ranked nothing' says NO priority order — never both" $rc

# ── 6b) AN UNVERIFIABLE COUNT IS NOT A DRAINED QUEUE (review P2) ────────────
# `rank_queue_by_pool` writes `<ranked> <unranked> <head>` and the caller reads it to choose its
# state word. `0 0` is the DRAINED-QUEUE claim, so a count that cannot be read must fail the reorder
# where the caller can still say `priority-unreadable` — never arrive as zeros and be reported as
# “the queue is EMPTY — there is nothing to order” over a queue that is not empty (the same convention
# this file already applies to an unreadable pool row count, #1931). `/dev/null` is the fixture for
# it: the write SUCCEEDS (awk exits 0) and the file is permanently `-s`-empty, so the guard, and only
# the guard, decides the outcome.
#
# Positive pair in the same check: the identical call with a REAL count path must succeed, so a
# producer that simply always failed could not satisfy this assertion.
QC="$TMP/countguard"; mkdir -p "$QC"
printf '300\n9\n' > "$QC/q"
printf '300\n' > "$QC/pool"
{
  cat "$FNS"
  printf 'rank_queue_by_pool "$1" "$2" "$3" "$4"\nexit $?\n'
} > "$QC/one.sh"
( cd "$QC" && HOME="$QC" bash one.sh "$QC/pool" "$QC/q" "$QC/out-bad" /dev/null ) >/dev/null 2>&1
bad_rc=$?
( cd "$QC" && HOME="$QC" bash one.sh "$QC/pool" "$QC/q" "$QC/out-good" "$QC/cnt-good" ) >/dev/null 2>&1
good_rc=$?
if [ "$bad_rc" -ne 0 ] && [ -s "$QC/out-bad" ] && [ "$good_rc" -eq 0 ] && [ -s "$QC/cnt-good" ]; then rc=0
else
  rc=1; echo "      unverifiable-count rc=$bad_rc (want !=0, with a written reorder); real-count rc=$good_rc (want 0, count written)"
fi
ck "a reorder whose COUNT cannot be verified FAILS instead of reporting a drained queue (positive pair: a real count succeeds)" $rc

# ── 7) THE WIRING CANNOT GO INERT — the false-PASS this suite was written for ──
# The first cut of this change DEFINED both functions ~1,337 lines BELOW the skip arm that calls one, so
# on every skipped pass bash resolved the call to nothing (`command not found`, absorbed by `|| true`)
# and the reorder never ran. A definition that lives after its call site is indistinguishable from no
# function at all at runtime, and every assertion above still passes because they supply their own call.
#
# ⛔ POSITION IS NOT REACHABILITY (review P1, cycle 3). Pinning only "both calls sit below the
# definition" leaves the DEFECT IT NAMES alive: moving the skip arm's call BELOW that arm's own
# `exit 0` keeps it after the definition, keeps the count at 2, and keeps this check GREEN — while the
# skip path, the COMMON path the PR's own measurement is about (23 minutes of skipped passes), never
# reorders again. So the skip arm's call is pinned by CONTAINMENT: it must sit inside the arm, between
# `refresh_stage skip "digest compare` and that arm's `exit 0`.
skip_call_line() {  # <file> -> the line number of a call INSIDE the skip arm, or empty
  awk '
    /^[[:space:]]*refresh_stage skip "digest compare/{ arm = 1; next }
    arm && /^[[:space:]]*exit 0[[:space:]]*$/{ exit }
    arm && /queue_order_from_pool "\$O"/{ print NR; exit }
  ' "$1"
}
def_line="$(grep -n '^queue_order_from_pool() {' "$REFRESH" | head -1 | cut -d: -f1)"
call_lines="$(grep -n 'queue_order_from_pool "\$O"' "$REFRESH" | cut -d: -f1 | tr '\n' ' ' | sed 's/ *$//')"
call_n="$(grep -c 'queue_order_from_pool "\$O"' "$REFRESH")"
skip_in_arm="$(skip_call_line "$REFRESH")"
bad_calls=""
for c in $call_lines; do
  [ -n "$def_line" ] && [ "$c" -gt "$def_line" ] || bad_calls="$bad_calls $c"
done
if [ -n "$def_line" ] && [ "$call_n" -eq 2 ] && [ -z "$bad_calls" ] && [ -n "$skip_in_arm" ]; then rc=0
else
  rc=1
  echo "      def_line='$def_line' call_n='$call_n' calls='$call_lines' BEFORE-def:${bad_calls:-none} skip-arm-call='${skip_in_arm:-MISSING}'"
  echo "      (want: a definition, exactly 2 call sites — the skip arm and the main pass — both AFTER it, and the skip arm's INSIDE the arm, before its exit 0)"
fi
ck "both call sites FOLLOW the definitions AND the skip arm's call is REACHABLE — inside the arm, before its exit 0 (def at line ${def_line:-?})" $rc

# 7b) NON-VACUITY: a definition placed AFTER a call site must redden it — the defect this check was
#     born for. Built here rather than read from git history so it does not depend on a commit.
MOVED="$TMP/moved.sh"
{ printf 'queue_order_from_pool "$O"\n'; cat "$FNS"; } > "$MOVED"
mdef="$(grep -n '^queue_order_from_pool() {' "$MOVED" | head -1 | cut -d: -f1)"
mcall="$(grep -n 'queue_order_from_pool "\$O"' "$MOVED" | head -1 | cut -d: -f1)"
[ -n "$mdef" ] && [ -n "$mcall" ] && [ "$mcall" -lt "$mdef" ] && rc=0 || { rc=1; echo "      moved fixture: call=$mcall def=$mdef"; }
ck "non-vacuity: the wiring pin reddens on a definition placed AFTER its call site" $rc

# 7c) NON-VACUITY of the REACHABILITY half: the same arm shape with the call moved below its `exit 0`
#     must produce NO line from skip_call_line — otherwise the containment pin is a phrase, and this is
#     exactly the mutation a position-only pin stays green on.
INERT="$TMP/skip-inert.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  exit 0' \
  '  queue_order_from_pool "$O" || true' > "$INERT"
if [ -z "$(skip_call_line "$INERT")" ]; then rc=0
else rc=1; echo "      a call below the arm's exit 0 still read as reachable (line $(skip_call_line "$INERT"))"; fi
ck "non-vacuity: the reachability pin reddens on a skip call moved BELOW the arm's exit 0 (position-only pins stay green there)" $rc

# ── 8) A REORDER THAT CHANGES NOTHING DOES NOT SWAP THE INODE ────────────────
# `mv` REPLACES candidates.txt, and the dispatch prune truncates that file IN PLACE, without
# `.refresh.lock`, while this refresh runs BACKGROUNDED — so every avoidable swap is a chance to revert
# a prune, and a read that catches the truncate window would `mv` a ZERO-BYTE file over the queue and
# destroy its membership (the one thing "order, never membership" forbids). An identical reorder must
# therefore write NOTHING. The positive pair keeps this from being satisfied by a dead writer.
ID="$TMP/inode"; mkdir -p "$ID/o"
inode_of() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
{
  echo 'QUEUE_ORDER_STATE=""'
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nexit 0\n'
} > "$ID/drive.sh"
# A) ALREADY IN POOL ORDER -> identical bytes -> no swap.
printf '200\n300\n9\n' > "$ID/o/candidates.txt"
printf '200\n300\n' > "$ID/o/.pool"
ino_a1="$(inode_of "$ID/o/candidates.txt")"
( cd "$ID" && HOME="$ID" bash drive.sh "$ID/o" ) >/dev/null 2>&1
ino_a2="$(inode_of "$ID/o/candidates.txt")"
order_a="$(tr '\n' ' ' < "$ID/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
# B) POSITIVE PAIR: a queue that IS out of pool order -> the reorder must actually land on disk.
printf '9\n300\n200\n' > "$ID/o/candidates.txt"
ino_b1="$(inode_of "$ID/o/candidates.txt")"
( cd "$ID" && HOME="$ID" bash drive.sh "$ID/o" ) >/dev/null 2>&1
ino_b2="$(inode_of "$ID/o/candidates.txt")"
order_b="$(tr '\n' ' ' < "$ID/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
if [ -n "$ino_a1" ] && [ "$ino_a1" = "$ino_a2" ] && [ "$order_a" = "200 300 9" ] \
   && [ "$ino_b1" != "$ino_b2" ] && [ "$order_b" = "200 300 9" ]; then rc=0
else
  rc=1; echo "      identical reorder inode $ino_a1 -> $ino_a2 (want equal), order '$order_a'; real reorder inode $ino_b1 -> $ino_b2 (want differ), order '$order_b'"
fi
ck "an IDENTICAL reorder does not swap the file's inode, and a real one still does (no needless rewrite, no dead writer)" $rc

# ── 9) THE QUEUE MUST BE A READABLE REGULAR FILE, AND "DRAINED" IS AN EARNED WORD ──────────
# `[ -s ]` answers "is the size non-zero", not "can this be read as a queue". Measured on the shipped
# function: a queue that is a DIRECTORY made awk SKIP it (`warning: … is a directory: skipped`), after
# which the rank emitted the POOL's rows as if they were queued (count `0 2 -`, rc 0) and the caller
# reported "the pool ranked NONE of the 2 queued" — membership ADDED, and a false statement. An ABSENT
# queue was reported as a measured DRAINED one and a 0-byte file was created (#1931's prohibition).
# Both must now be `priority-unreadable`, with nothing written.
GQ="$TMP/guards"; mkdir -p "$GQ"
printf '200\n300\n' > "$GQ/pool"
mkdir -p "$GQ/absent-o" "$GQ/dir-o/candidates.txt"
# ⛔ THE POOL GOES INSIDE EACH $o, WHERE THE DRIVEN CODE ACTUALLY READS IT (review P1, cycle 6).
# `queue_order_from_pool` reads `$o/.pool`; the first version wrote ONE pool at `$GQ/pool` and drove
# `$GQ/absent-o` / `$GQ/dir-o`, so in BOTH sub-cases the pass aborted at the POOL guard — one line
# below the queue guard this check exists to pin — and the assertions were satisfied by the wrong
# guard entirely. Measured: with the queue-shape guard DELETED the suite stayed `23 passed, 0 failed`,
# so this check asserted nothing about it. With a pool present, the same mutant reports an ABSENT queue
# as a MEASURED drained one, CREATES a 0-byte candidates.txt and exits 0 — the #1931 prohibition named
# in this check's own title, unpinned. A fixture that never reaches the guard is a check about a path
# the code does not take.
cp "$GQ/pool" "$GQ/absent-o/.pool"
cp "$GQ/pool" "$GQ/dir-o/.pool"
{
  echo 'QUEUE_ORDER_STATE=""'
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nexit $?\n'
} > "$GQ/drive.sh"
( cd "$GQ" && HOME="$GQ" bash drive.sh "$GQ/absent-o" ) > "$GQ/absent.log" 2>&1
absent_rc=$?
( cd "$GQ" && HOME="$GQ" bash drive.sh "$GQ/dir-o" ) > "$GQ/dir.log" 2>&1
dir_rc=$?
if [ "$absent_rc" -ne 0 ] && [ ! -e "$GQ/absent-o/candidates.txt" ] \
   && grep -q 'priority-unreadable' "$GQ/absent.log" 2>/dev/null \
   && [ "$dir_rc" -ne 0 ] && [ -d "$GQ/dir-o/candidates.txt" ] \
   && [ ! -e "$GQ/dir-o/candidates.txt/.cand.ranked" ] \
   && grep -q 'priority-unreadable' "$GQ/dir.log" 2>/dev/null; then rc=0
else
  rc=1; echo "      absent: rc=$absent_rc created=$( [ -e "$GQ/absent-o/candidates.txt" ] && echo yes || echo no ); dir: rc=$dir_rc moved-in=$( [ -e "$GQ/dir-o/candidates.txt/.cand.ranked" ] && echo yes || echo no )"
fi
ck "an ABSENT or NON-REGULAR queue is 'priority-unreadable' with NOTHING written — never a drained queue, never pool rows installed" $rc

# ── 10) A REWRITE IS REPORTED AS A REWRITE ──────────────────────────────────
# The ranked-none arm CAN write: `qseen` collapses a DUPLICATE row, so `300 9 300` comes out `300 9` and
# the install runs. The message must then say it rewrote — "byte-identical" was a typed claim about a
# write this call had just performed, and test 4 above pins the opposite half on a fixture with no
# duplicates, so the pair discriminates.
drive dupnone "$FNS" '300
9
300
' '777
'
dup_order="$(cat "$TMP/dupnone/order" 2>/dev/null)"
if [ "$dup_order" = "300 9" ] && grep -q 'WAS rewritten' "$TMP/dupnone/out" 2>/dev/null \
   && ! grep -q 'byte-identical' "$TMP/dupnone/out" 2>/dev/null; then rc=0
else rc=1; echo "      order '$dup_order' (want '300 9'); out: $(tr '\n' '|' < "$TMP/dupnone/out" 2>/dev/null | head -c 260)"; fi
ck "the ranked-none arm that DID rewrite (a duplicate collapsed) says so, and does not claim 'byte-identical'" $rc

# ── 11) THE PRUNE THAT LANDS BETWEEN THE READ AND THE INSTALL IS REFUSED ─────
# orch-loop.sh prunes candidates.txt with `open(path,"w")` — truncate IN PLACE, no `.refresh.lock` —
# while this refresh runs BACKGROUNDED. The ordering that matters: the pass reads an EMPTY queue (the
# truncate window) and the prune REFILLS it before the file is replaced. The membership check used to
# live in `rank_queue_by_pool`, which returns EARLY on the drained arm — so on this exact ordering it
# never ran, `.cand.ranked` was the empty file, `cmp` differed against the refilled queue, and `mv`
# installed a ZERO-BYTE queue while the pass reported a MEASURED "the queue is EMPTY". Modelled
# deterministically with a `cmp` shim on PATH that refills the queue before comparing (no mutation of
# the code under test): the install must be REFUSED and the rows must survive.
SH="$TMP/prunerace"; mkdir -p "$SH/o" "$SH/bin"
printf '111\n222\n' > "$SH/seed"
printf '200\n300\n' > "$SH/o/.pool"
: > "$SH/o/candidates.txt"
cat > "$SH/bin/cmp" <<'SHIM'
#!/usr/bin/env bash
# model the concurrent prune: refill the queue, THEN compare for real
cp "$PRUNE_SEED" "$PRUNE_QUEUE" 2>/dev/null || true
exec /usr/bin/cmp "$@"
SHIM
chmod +x "$SH/bin/cmp"
{
  echo 'QUEUE_ORDER_STATE=""'
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nexit $?\n'
} > "$SH/drive.sh"
( cd "$SH" && HOME="$SH" PATH="$SH/bin:$PATH" PRUNE_SEED="$SH/seed" PRUNE_QUEUE="$SH/o/candidates.txt" bash drive.sh "$SH/o" ) > "$SH/out" 2>&1
race_rc=$?
race_rows="$(tr '\n' ' ' < "$SH/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
if [ "$race_rc" -ne 0 ] && [ "$race_rows" = "111 222" ] \
   && grep -q 'priority-unreadable' "$SH/out" 2>/dev/null \
   && ! grep -q 'the queue is EMPTY' "$SH/out" 2>/dev/null \
   && [ ! -e "$SH/o/.cand.ranked" ]; then rc=0
else rc=1; echo "      rc=$race_rc rows='$race_rows' (want '111 222'); out: $(tr '\n' '|' < "$SH/out" 2>/dev/null | head -c 300)"; fi
ck "a prune that refills the queue between the read and the install is REFUSED — the rows survive, no 'EMPTY' is reported" $rc

echo "── rank-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
