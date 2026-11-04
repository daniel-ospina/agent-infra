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
[ "$mut" = "200 300" ] && rc=0 || { rc=1; echo "      mutated source gave '$mut' (want the dropped-tail '200 300' — the mutation is LIVE, so the membership checks below can fail)"; }
ck "mutation is LIVE: dropping the unranked tail loses the tail rows ('9' disappears)" $rc

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

# 2b) NON-VACUITY of the membership check: run it against the tail-dropping mutation and require it to
#     fail. This is the check that catches "the reorder silently discards a CLEAN-judged candidate".
drive mut-member "$MUT_DROP_TAIL" '5000
100
9000
5000
' '100
'
mut_set="$(sort -n "$TMP/mut-member/o/candidates.txt" 2>/dev/null | uniq | tr '\n' ' ' | sed 's/ *$//')"
[ "$mut_set" != "$before_set" ] && rc=0 || { rc=1; echo "      mutated source kept the set '$mut_set' — the membership assertion is vacuous"; }
ck "non-vacuity: the membership assertion FAILS on the tail-dropping mutation" $rc

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
# ⛔ AND IT MAY NAME "ARRIVAL ORDER" HERE (review P2, cycle 2) — this is the ONE arm that may, because
# the file really was rewritten and the pool ranked nothing in it. That makes the ABSENCE asserted in
# test 6 below discriminating rather than a phrase nobody ever emits.
if [ "$same" -eq 0 ] && grep -q 'priority-unreadable' "$TMP/norank/out" 2>/dev/null \
   && grep -q 'ARRIVAL order' "$TMP/norank/out" 2>/dev/null \
   && ! grep -q 'severity-first' "$TMP/norank/out" 2>/dev/null; then rc=0
else
  rc=1; echo "      same=$same; out: $(tr '\n' '|' < "$TMP/norank/out" 2>/dev/null | head -c 300)"
fi
ck "a pool ranking NONE of the queue says 'priority-unreadable', leaves the file byte-identical, names ARRIVAL order, and never claims severity" $rc

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

# 6a-bis) AND THE DISTINCTION IS REAL, not a phrase dropped everywhere: test 4 above still REQUIRES
#     'ARRIVAL order' on the arm that genuinely rewrote the file. Re-drive it here so the pair cannot
#     drift apart (a later edit that deletes the phrase from BOTH messages reds exactly one of them).
drive norank2 "$FNS" '300
9
' '777
'
if grep -q 'ARRIVAL order' "$TMP/norank2/out" 2>/dev/null; then rc=0
else rc=1; echo "      out: $(tr '\n' '|' < "$TMP/norank2/out" 2>/dev/null | head -c 300)"; fi
ck "non-vacuity pair: the pool-ranked-nothing arm still names ARRIVAL order, so the absence in 6a is discriminating" $rc

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
# So pin the ORDER of the shipped text: both call sites must FOLLOW the definition.
def_line="$(grep -n '^queue_order_from_pool() {' "$REFRESH" | head -1 | cut -d: -f1)"
call_lines="$(grep -n 'queue_order_from_pool "\$O"' "$REFRESH" | cut -d: -f1 | tr '\n' ' ' | sed 's/ *$//')"
call_n="$(grep -c 'queue_order_from_pool "\$O"' "$REFRESH")"
bad_calls=""
for c in $call_lines; do
  [ -n "$def_line" ] && [ "$c" -gt "$def_line" ] || bad_calls="$bad_calls $c"
done
if [ -n "$def_line" ] && [ "$call_n" -eq 2 ] && [ -z "$bad_calls" ]; then rc=0
else
  rc=1
  echo "      def_line='$def_line' call_n='$call_n' calls='$call_lines' BEFORE-def:${bad_calls:-none}"
  echo "      (want: a definition, exactly 2 call sites — the skip arm and the main pass — and both AFTER it)"
fi
ck "both call sites FOLLOW the definitions (2 call sites, def at line ${def_line:-?}) — the reorder cannot go inert" $rc

# 7b) NON-VACUITY of the wiring pin: a source with the definition MOVED below one call site must redden
#     it. Built here rather than read from git history so the check does not depend on a commit.
MOVED="$TMP/moved.sh"
{ printf 'queue_order_from_pool "$O"\n'; cat "$FNS"; } > "$MOVED"
mdef="$(grep -n '^queue_order_from_pool() {' "$MOVED" | head -1 | cut -d: -f1)"
mcall="$(grep -n 'queue_order_from_pool "\$O"' "$MOVED" | head -1 | cut -d: -f1)"
[ -n "$mdef" ] && [ -n "$mcall" ] && [ "$mcall" -lt "$mdef" ] && rc=0 || { rc=1; echo "      moved fixture: call=$mcall def=$mdef"; }
ck "non-vacuity: the wiring pin reddens on a definition placed AFTER its call site" $rc

echo "── rank-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
