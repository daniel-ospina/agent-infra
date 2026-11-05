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
#   7. The PRODUCT FLOOR'S FILE FOLLOWS the order a pass installs: `candidates.product.txt` is read by
#      `orch-loop.sh`'s `floor_order` in ITS OWN order, and the skip arm returns before the split that
#      would otherwise derive it — so without check 12 the floor's head could be chosen by a sequence the
#      pass no longer maintains (order only; the row set is compared, never changed).
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

# ── 2c) THE FILES ARE TOLD APART BY IDENTITY, NOT BY POSITION (review P2, cycle 6) ──
# `NR == FNR` means "the FIRST file" only while that file yields records. `orch-loop.sh` prunes
# candidates.txt with an in-place truncate (`open(path,"w")`) and takes no `.refresh.lock`, so a read can
# begin against a NON-EMPTY queue and reach the awk as a ZERO-RECORD first file; with `NR == FNR` the
# first POOL row then satisfies the test and the whole pool is taken for the queue — pool rows emitted
# as queue rows, i.e. MEMBERSHIP added, the one thing "order, never membership" forbids. The shipped
# `FILENAME == ARGV[1]` is the file's IDENTITY and cannot be true for the pool whatever the queue did.
# ⚠️ This is pinned against the shipped AWK TEXT, because the state is unobservable through
# `queue_order_from_pool`: its empty-queue arm returns before the awk ever runs, so ONLY the race
# reaches this line. Driving the program itself is the only honest way to pin it — and reverting it to
# `NR == FNR` leaves every other check in this suite green (measured: 23 passed / 0 failed), so nothing
# above this point covers it.
DRQ="$TMP/file-identity"; mkdir -p "$DRQ"
awk -v sq="$(printf '\047')" '
  index($0, "awk -v cntf=") { f = 1; i = index($0, sq); if (i) $0 = substr($0, i + 1) }
  f && index($0, "close(cntf) }") { i = index($0, sq); if (i) $0 = substr($0, 1, i - 1); print; exit }
  f { print }
' "$FNS" > "$DRQ/rank.awk" 2>/dev/null
grep -q 'FILENAME == ARGV\[1\]' "$DRQ/rank.awk" 2>/dev/null && mutated=1 || mutated=0
[ "$mutated" -eq 1 ] && rc=0 || { rc=1; echo "      could not extract the shipped awk program (no FILENAME test found in $FNS)"; }
ck "the shipped ranker's awk program can be extracted for direct drive (it still tells the files apart by identity)" $rc
printf '' > "$DRQ/empty"
printf '200\n300\n' > "$DRQ/pool"
awk -v cntf="$DRQ/cnt-empty" -f "$DRQ/rank.awk" "$DRQ/empty" "$DRQ/pool" > "$DRQ/out-empty" 2>/dev/null
[ ! -s "$DRQ/out-empty" ] && rc=0 || { rc=1; echo "      a ZERO-RECORD first file emitted $(tr '\n' ' ' < "$DRQ/out-empty") — pool rows are being taken for the queue"; }
ck "a ZERO-RECORD first file emits NOTHING — the pool is never mistaken for the queue (count '$(cat "$DRQ/cnt-empty" 2>/dev/null)')" $rc
# NON-VACUITY: the pre-hardening test must exhibit the defect on this very fixture, or the two checks
# above assert nothing about the code that is actually shipped.
sed 's/FILENAME == ARGV\[1\]/NR == FNR/' "$DRQ/rank.awk" > "$DRQ/rank-nrfnr.awk"
grep -q 'NR == FNR' "$DRQ/rank-nrfnr.awk" && mutated=1 || mutated=0
[ "$mutated" -eq 1 ] && rc=0 || { rc=1; echo "      the NR==FNR mutation did not apply"; }
ck "the NR==FNR mutation applied to the extracted program" $rc
awk -v cntf="$DRQ/cnt-mut" -f "$DRQ/rank-nrfnr.awk" "$DRQ/empty" "$DRQ/pool" > "$DRQ/out-mut" 2>/dev/null
if [ "$(tr '\n' ' ' < "$DRQ/out-mut" | sed 's/ *$//')" = "200 300" ] && [ "$(cat "$DRQ/cnt-mut" 2>/dev/null)" = "0 2 -" ]; then rc=0
else rc=1; echo "      NR==FNR gave '$(tr '\n' ' ' < "$DRQ/out-mut" | sed 's/ *$//')' / '$(cat "$DRQ/cnt-mut" 2>/dev/null)' (want the pool installed as the queue: '200 300' / '0 2 -')"; fi
ck "non-vacuity: NR==FNR INSTALLS the pool as the queue on a zero-record first file — the identity test is load-bearing, not cosmetic" $rc

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

# ── 3b) THE COUNTS ARE PART OF THE PRODUCT, NOT DECORATION (review P1, cycle 6) ───────────────────
# The PR body and ARCHITECTURE.md both advertise that unranked rows are "KEPT at the TAIL and counted",
# and that printed count is the ONLY thing that lets an unranked population be distinguished from a
# ranked one in the log. NOTHING pinned it: measured on the shipped script, removing the parenthetical
# from the severity line AND deleting the WARN line outright left this suite at `23 passed, 0 failed`.
# A safety property whose only regression path is a silent one-line edit is exactly the false PASS this
# PR exists to close elsewhere, so both prints are pinned here on the SAME fixture as 3), with the
# VALUES asserted (2 ranked / 2 unranked), so a count that stops counting reddens as well.
tail_out="$(cat "$TMP/tail/out" 2>/dev/null)"
case "$tail_out" in
  *"(2 pool-ranked, 2 unranked at the tail)"*) rc=0 ;;
  *) rc=1; echo "      the severity line does not carry the measured counts (want '(2 pool-ranked, 2 unranked at the tail)'); out: $(printf '%s' "$tail_out" | head -c 240)" ;;
esac
ck "the severity-first line PRINTS the counts — '2 pool-ranked, 2 unranked at the tail' for pool '200,300' over queue '9,300,7,200'" $rc
case "$tail_out" in
  *"WARN queue order: 2 queued candidate(s) are not ranked"*) rc=0 ;;
  *) rc=1; echo "      the unranked-population WARN is missing (want 'WARN queue order: 2 queued candidate(s) are not ranked'); out: $(printf '%s' "$tail_out" | head -c 240)" ;;
esac
ck "an unranked population is ANNOUNCED — 'WARN queue order: 2 queued candidate(s) are not ranked', so it can never read as a fully ranked queue" $rc

# 3c) NON-VACUITY of 3b: strip both prints from the source the suite drives and confirm the mutant's
#     output no longer carries them. Without this, 3b could be satisfied by the fixture rather than by
#     the shipped print. This is the same removal that was measured GREEN before this check existed.
MUT_NOCOUNT="$TMP/fns-nocount.sh"
# ⛔ THE WARN LINE IS NEUTERED, NOT DELETED (review P2, cycle 8). `sed /…/d` removes the echo from inside
# its `if … then … fi`, leaving an EMPTY then-body: `bash -n` rejects the mutant, the drive below dies at
# rc=2 with EMPTY output, and the `*) rc=0` arm reads that CRASH as "the prints are gone" — the mutation
# would prove nothing while reporting green. `:` keeps the block valid, so the mutant parses and runs and
# the only difference is the absent lines.
sed -e 's/ (\$_r pool-ranked, \$_u unranked at the tail)//' \
    -e '/WARN queue order: \$_u queued candidate(s)/{s/.*/    : MUTANT_NO_WARN/}' "$FNS" > "$MUT_NOCOUNT"
bash -n "$MUT_NOCOUNT" 2>/dev/null || { rc=1; echo "      the count/WARN mutation left an UNPARSABLE source"; ck "the count/WARN mutation keeps the extracted source parsable" $rc; }
case "$(cat "$MUT_NOCOUNT" 2>/dev/null)" in
  *'pool-ranked, $_u unranked'*|*'WARN queue order: $_u queued'*) mutated=1 ;;
  *) mutated=0 ;;
esac
case "$(cat "$MUT_NOCOUNT" 2>/dev/null)" in
  *'MUTANT_NO_WARN'*) mutated_neutered=1 ;;
  *) mutated_neutered=0 ;;
esac
[ "$mutated" -eq 0 ] && [ "$mutated_neutered" -eq 1 ] && rc=0 || { rc=1; echo "      the count/WARN mutation did not apply cleanly — a sed anchor drifted, or the WARN line was DELETED (leaving an empty then-body) rather than neutered"; }
ck "the count-stripping mutation applied to the extracted source (both anchors still match it)" $rc
drive mut-nocount "$MUT_NOCOUNT" '9
300
7
200
' '200
300
'
nc_out="$(cat "$TMP/mut-nocount/out" 2>/dev/null)"
nc_order="$(cat "$TMP/mut-nocount/order" 2>/dev/null)"
case "$nc_out" in
  *'pool-ranked'*|*'WARN queue order'*) rc=1; echo "      the mutant still prints a count/WARN — 3b cannot discriminate"; out_tail="$(printf '%s' "$nc_out" | grep -o 'pool-ranked\|WARN queue order' | head -2 | tr '\n' ' ')"; echo "      still present: $out_tail" ;;
  *) [ "$nc_order" = "200 300 9 7" ] && rc=0 || { rc=1; echo "      the mutant's drive did not RUN (order '$nc_order', want '200 300 9 7') — an absent print on a CRASHED drive proves nothing"; } ;;
esac
ck "non-vacuity: with both prints removed the 3b assertions go RED (the removal is visible, not absorbed)" $rc

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
# The first cut of this change (`70ea113c`) left both definitions OUTSIDE the region the sibling check
# DRIVES: `selftest.sh` builds its fixture from the `^done < "$O/.pool"` anchor onward, and on that
# commit `rank_queue_by_pool`/`queue_order_from_pool` sat at 3709/3742 against an anchor at 4827 — i.e.
# ~1,085 lines ABOVE it — so in the driven copy bash resolved the call to nothing (`command not found`,
# absorbed by `|| true`) and the reorder never ran. A definition that lives outside the region a drive
# executes is indistinguishable from no function at all at runtime, and every assertion above still
# passes because they supply their own call.
# ⛔ THE DIRECTION AND THE ANCHOR IN THIS COMMENT WERE CORRECTED (review P2, cycle 6). It used to say
# "DEFINED both functions ~1,337 lines BELOW the skip arm" — measured false on `70ea113c`: the
# definition was at 3742 and the skip-arm call at 3810, so it was 68 lines ABOVE that call. The ~1,337
# magnitude is the definition → MAIN-call distance (1,467 at HEAD, `:3813` → `:5280`), not the defect.
# The assertion below is sound either way; only the story it told was wrong.
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

# ── 12) THE PRODUCT FLOOR'S FILE FOLLOWS THE ORDER THIS PASS INSTALLED ───────────────────────
# `orch-loop.sh`'s `floor_order` walks `candidates.product.txt` in ITS OWN order and takes up to
# `PRODUCT_FLOOR` (default 1) rows that ALSO live in candidates.txt. On a MAIN pass `write_product_queues`
# derives it from candidates.txt, so the two agree; the SKIP arm returns before that split, so without
# `product_queue_follow` the product file keeps the PREVIOUS pass's sequence while the queue it is
# intersected with moves — and the floor slot is then chosen by an order the pass no longer maintains
# (membership is unaffected, which is why the exposure is the floor slot alone).
# ⛔ THE WIRING FIRST (the same lesson as check 7): the function being right is worthless if the skip arm
# never calls it — or calls it BEFORE the queue is re-ordered, in which case it copies the OLD order
# forward. So the call is pinned by CONTAINMENT inside the arm and by ORDER after the queue's call.
skip_arm_call() {  # <marker-text> <file> -> line of that CALL inside the skip arm, or empty
  awk -v want="$1" '
    /^[[:space:]]*refresh_stage skip "digest compare/{ arm = 1; next }
    arm && /^[[:space:]]*exit 0[[:space:]]*$/{ exit }
    arm && /^[[:space:]]*#/ { next }
    arm { line = $0; sub(/#.*/, "", line); if (index(line, want)) { print NR; exit } }
  ' "$2"
}
# 12-w0) THE ORDER PREDICATE, in ONE place: the shipped check and the reversed fixture below must drive the
#        SAME function, or the reversed fixture pins only its own comparison and a predicate degenerated to
#        "both calls present" passes green (measured at VGATE pass 4).
arm_order_ok() {  # <queue-line> <product-line> -> true when BOTH were found AND the product call FOLLOWS
  [ -n "$1" ] && [ -n "$2" ] && [ "$2" -gt "$1" ]
}
q_in_arm="$(skip_arm_call 'queue_order_from_pool "$O"' "$REFRESH")"
pf_in_arm="$(skip_arm_call 'product_queue_follow "$O"' "$REFRESH")"
if arm_order_ok "$q_in_arm" "$pf_in_arm"; then rc=0
else rc=1; echo "      skip-arm calls: queue_order_from_pool='${q_in_arm:-MISSING}' product_queue_follow='${pf_in_arm:-MISSING}' (want both present, the product call AFTER the queue's)"; fi
ck "the SKIP arm calls product_queue_follow, and AFTER the queue reorder it must follow (queue line ${q_in_arm:-?}, product line ${pf_in_arm:-?})" $rc
# 12-w) NON-VACUITY of the wiring pin, BOTH directions:
#       (a) the product call moved BELOW the arm's `exit 0` must produce NO line — otherwise an inert
#           call satisfies a position-only pin; and
#       (b) a COMMENTED-OUT call inside the arm must produce NO line either (review P2, cycle 8): a raw
#           substring match counted `# product_queue_follow "$O"` as the call, so an arm whose only
#           "call" was a comment would satisfy a checkmark claiming the arm CALLS it.
#       Both fixtures carry a REAL queue call, so a scanner that found nothing at all cannot pass either.
INERTPF="$TMP/pf-inert.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  queue_order_from_pool "$O" || true' \
  '  exit 0' \
  '  product_queue_follow "$O" || true' > "$INERTPF"
COMMENTPF="$TMP/pf-comment.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  queue_order_from_pool "$O" || true' \
  '  # product_queue_follow "$O" || true' \
  '  exit 0' > "$COMMENTPF"
REVERSEDPF="$TMP/pf-reversed.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  product_queue_follow "$O" || true' \
  '  queue_order_from_pool "$O" || true' \
  '  exit 0' > "$REVERSEDPF"
INLINEPF="$TMP/pf-inline-comment.sh"
printf '%s\n' \
  '  refresh_stage skip "digest compare (fixture)"' \
  '  queue_order_from_pool "$O" || true' \
  '  : # product_queue_follow "$O" || true' \
  '  exit 0' > "$INLINEPF"
below_exit0="$(skip_arm_call 'product_queue_follow "$O"' "$INERTPF")"
commented="$(skip_arm_call 'product_queue_follow "$O"' "$COMMENTPF")"
inline_commented="$(skip_arm_call 'product_queue_follow "$O"' "$INLINEPF")"
q_live_a="$(skip_arm_call 'queue_order_from_pool "$O"' "$INERTPF")"
q_live_b="$(skip_arm_call 'queue_order_from_pool "$O"' "$COMMENTPF")"
q_live_c="$(skip_arm_call 'queue_order_from_pool "$O"' "$INLINEPF")"
if [ -z "$below_exit0" ] && [ -z "$commented" ] && [ -z "$inline_commented" ] \
   && [ -n "$q_live_a" ] && [ -n "$q_live_b" ] && [ -n "$q_live_c" ]; then rc=0
else
  rc=1; echo "      below-exit0='${below_exit0:-none}' commented='${commented:-none}' inline='${inline_commented:-none}' (want none/none/none) with queue call found in every fixture ('${q_live_a:-MISSING}'/'${q_live_b:-MISSING}'/'${q_live_c:-MISSING}')"
fi
ck "non-vacuity: the reachability pin reddens on a product call BELOW the arm's exit 0, on a full-line COMMENT, and on an INLINE-commented one" $rc
# 12-x) WHERE THE CALLS SIT, not merely THAT they exist (review P2, cycle 9). Two positions carry the fix
#        and neither was pinned:
#        (a) the MAIN call must run BEFORE `write_product_queues`, which derives candidates.product.txt
#            from candidates.txt's order at that moment — run the reorder after it and the product queue is
#            built from the PRE-reorder order, so `floor_order` again takes its head from arrival order.
#            Moving it below the split kept the suite GREEN at 42/0.
#        (b) the skip arm's calls must run BEFORE the head/backlog read (`_skip_head=`), which reports the
#            queue's head to the durable record; run them after and the record names a row that is no
#            longer the head while asserting it is the highest-ranked CLEAN entry.
#        ONE predicate, driven by both the shipped check and its reversed fixture — the lesson of 12-w0
#        (a fixture that compares the numbers itself pins nothing but itself).
before_ok() {  # <earlier-line> <later-line> -> true when BOTH were found AND the first precedes the second
  [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]
}
main_call_line="$(grep -n '^queue_order_from_pool "\$O" || true' "$REFRESH" | head -1 | cut -d: -f1)"
split_line="$(grep -nF 'write_product_queues "$O"' "$REFRESH" | head -1 | cut -d: -f1)"
if before_ok "$main_call_line" "$split_line"; then rc=0
else rc=1; echo "      main call '${main_call_line:-MISSING}' vs write_product_queues '${split_line:-MISSING}' — the reorder must run BEFORE the split (after it, the product queue is derived from the pre-reorder order)"; fi
ck "the MAIN reorder runs BEFORE write_product_queues derives the product queue (call ${main_call_line:-?} < split ${split_line:-?})" $rc
if ! before_ok "$split_line" "$main_call_line"; then rc=0
else rc=1; echo "      reversed: before_ok accepted (split=${split_line:-none}, call=${main_call_line:-none}) — 'before' cannot be distinguished from 'present'"; fi
ck "non-vacuity: the split/call ORDER pin reddens on the reversed pair (split '${split_line:-?}' before call '${main_call_line:-?}')" $rc
head_read_line="$(grep -n '^    _skip_head=""' "$REFRESH" | head -1 | cut -d: -f1)"
if before_ok "$pf_in_arm" "$head_read_line" && before_ok "$q_in_arm" "$head_read_line"; then rc=0
else rc=1; echo "      skip calls queue='${q_in_arm:-MISSING}' product='${pf_in_arm:-MISSING}' vs head read '${head_read_line:-MISSING}' — both must precede it, or the record names a head the reorder has superseded"; fi
ck "the SKIP arm's reorder AND follow run BEFORE the head/backlog read that the durable record quotes (both < ${head_read_line:-?})" $rc
if ! before_ok "$head_read_line" "$q_in_arm"; then rc=0
else rc=1; echo "      reversed: before_ok accepted head read '${head_read_line:-none}' before the queue call '${q_in_arm:-none}'"; fi
ck "non-vacuity: the head-read ORDER pin reddens on the reversed pair (head read '${head_read_line:-?}' before call '${q_in_arm:-?}')" $rc
# 12-w2) NON-VACUITY of the ORDER half, which the three fixtures above do NOT exercise (VGATE, cycle 9 —
#        it verified the predicate reds on the shipped tree, but the suite never re-proved that red itself,
#        so a rewrite of the comparison could go inert unnoticed). A REVERSED arm — product call BEFORE the
#        queue's — must not satisfy `pf -gt q`.
pf_rev="$(skip_arm_call 'product_queue_follow "$O"' "$REVERSEDPF")"
q_rev="$(skip_arm_call 'queue_order_from_pool "$O"' "$REVERSEDPF")"
if ! arm_order_ok "$q_rev" "$pf_rev"; then rc=0
  # (the predicate must REJECT a reversed arm: both calls ARE present there, so a presence-only
  #  comparison would accept it — which is the vacuity this fixture exists to redden)
else rc=1; echo "      reversed fixture: product line '${pf_rev:-none}' queue line '${q_rev:-none}' — arm_order_ok ACCEPTED a REVERSED arm, so the ORDER half cannot distinguish 'after' from 'merely present'"; fi
ck "non-vacuity: the ORDER half reddens on a REVERSED skip arm (product line ${pf_rev:-?} < queue line ${q_rev:-?}), so 'after' is not assumed from presence" $rc
# The assertion below is on the FLOOR'S OWN DECISION, driven from the shipped `floor_order`.
FLOORFNS="$TMP/floor-fns.sh"
awk '/^floor_order\(\) \{/{f=1} f && /^\}[[:space:]]*$/{print; exit} f' "$HERE/orch-loop.sh" > "$FLOORFNS"
if [ -s "$FLOORFNS" ] && grep -q '^floor_order() {' "$FLOORFNS"; then rc=0
else rc=1; echo "      could not extract floor_order from orch-loop.sh — check 12 cannot grade the floor"; fi
ck "the shipped floor_order is extracted WHOLE (the consumer this check drives)" $rc
# Driven as a SCRIPT, like every other drive in this suite, so the shipped function is executed rather
# than re-implemented here (a restatement of `head -1 of the product file` would pass on a broken floor).
{ cat "$FLOORFNS"; printf 'floor_order "$1" "$2" "$3"\n'; } > "$TMP/floor-drive.sh"
floor_head() {  # <product-file> <all-file> -> the row the floor's ONE slot takes
  ( cd "$TMP" && bash floor-drive.sh 1 "$1" "$2" ) 2>/dev/null | head -1
}
PQ="$TMP/productfollow"; mkdir -p "$PQ/o"
{
  echo 'QUEUE_ORDER_STATE=""'
  cat "$FNS"
  printf 'queue_order_from_pool "$1"\nproduct_queue_follow "$1"\n'
} > "$PQ/drive.sh"
inode_pf() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
# A) THE STALE CASE: the product file still leads with 200 while the queue has moved to 300 first.
#    ⛔ THE FIXTURE'S ORDER MUST NOT BE ASCENDING (VGATE, cycle 9). Seed `200 300` and "onto the queue's
#    order" is indistinguishable from `sort -n`: a `sort`-instead-of-follow implementation never opens
#    candidates.txt and still produced the expected bytes. The pool now ranks 300 BEFORE 200, so the
#    queue's order and the numeric sort disagree — the same reasoning section 1 applies to the queue
#    itself (a fixture whose two explanations coincide proves neither).
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '200\n300\n' > "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log" 2>&1
prod_a="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" 2>/dev/null | sed 's/ *$//')"
head_a="$(floor_head "$PQ/o/candidates.product.txt" "$PQ/o/candidates.txt")"
if [ "$(tr '\n' ' ' < "$PQ/o/candidates.txt" | sed 's/ *$//')" = "300 200" ] && [ "$prod_a" = "300 200" ] && [ "$head_a" = "300" ]; then rc=0
else rc=1; echo "      queue '$(tr '\n' ' ' < "$PQ/o/candidates.txt" | sed 's/ *$//')' product '$prod_a' floor-head '$head_a' (want 300 200 / 300 200 / 300 — the queue ARRIVED '200 300', so the reorder must really run; a numeric sort would leave the product at '200 300' and the head at 200)"; fi
ck "a SKIPPED pass re-sequences candidates.product.txt onto the queue's order, so the floor slot takes the queue's head (200 -> 300)" $rc
# B) NO NEEDLESS REWRITE: an already-aligned product file keeps its INODE (same reasoning as check 8 —
#    a swap races a reader for no gain). Positive pair: A above really did move bytes.
printf '300\n200\n9\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '300\n200\n' > "$PQ/o/candidates.product.txt"
ino1="$(inode_pf "$PQ/o/candidates.product.txt")"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log2" 2>&1
ino2="$(inode_pf "$PQ/o/candidates.product.txt")"
prod_b="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" | sed 's/ *$//')"
if [ -n "$ino1" ] && [ "$ino1" = "$ino2" ] && [ "$prod_b" = "300 200" ]; then rc=0
else rc=1; echo "      inode $ino1 -> $ino2 (want equal); product '$prod_b'"; fi
ck "an already-aligned product queue is not rewritten (inode unchanged), so the follow is not a needless swap" $rc
# C) MEMBERSHIP IS PRESERVED: a product row the queue does not hold is KEPT (in its own order), never
#    dropped — dropping it here would be a silent membership change in the file the floor reads.
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '777\n300\n555\n' > "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log3" 2>&1
prod_c="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" 2>/dev/null | sed 's/ *$//')"
if [ "$prod_c" = "300 777 555" ]; then rc=0
else rc=1; echo "      product '$prod_c' (want '300 777 555': the queue's order first, the unknown rows KEPT after it in THEIR order — a sort would emit '300 555 777')"; fi
ck "re-sequencing never changes the product file's ROW SET — a row candidates.txt does not hold is kept, not dropped" $rc
# C2) THE ROW-SET REFUSAL ITSELF (review P3, cycle 9). C above pins that the AWK preserves the row set; it
#     says nothing about the GUARD that refuses a write when the set differs — delete the guard and C still
#     passes, so its red path had never run. Modelled with a `sort` shim that reports ONE EXTRA row when the
#     product file is sorted (the file changing between the awk's read and the comparison is the only way
#     the guard can fire, and a concurrent writer is how): the re-sequence must be REFUSED, the file keeps
#     its old bytes, and the refusal names the row set.
RS="$TMP/rowset"; rm -rf "$RS"; mkdir -p "$RS/o" "$RS/bin"
printf '300\n200\n' > "$RS/o/candidates.txt"
printf '200\n300\n' > "$RS/o/candidates.product.txt"
cat > "$RS/bin/sort" <<'SHIM'
#!/usr/bin/env bash
# model a concurrent writer touching the product file between the two reads: one EXTRA row appears
if [ "${!#}" = "$RS_PF" ]; then { /usr/bin/sort "$@"; printf '999999\n'; }; else exec /usr/bin/sort "$@"; fi
SHIM
chmod +x "$RS/bin/sort"
{ echo 'QUEUE_ORDER_STATE=""'; cat "$FNS"; printf 'product_queue_follow "$1"\nexit $?\n'; } > "$RS/drive.sh"
( cd "$RS" && HOME="$RS" RS_PF="$RS/o/candidates.product.txt" PATH="$RS/bin:$PATH" bash drive.sh "$RS/o" ) > "$RS/out" 2>&1
rs_rows="$(tr '\n' ' ' < "$RS/o/candidates.product.txt" 2>/dev/null | sed 's/ *$//')"
rs_tmp="$(ls -a "$RS/o" 2>/dev/null | grep -c '^\.product\.follow$')"
if [ "$rs_rows" = "200 300" ] && [ "$rs_tmp" -eq 0 ] && grep -q 'would have CHANGED its row set' "$RS/out" 2>/dev/null; then rc=0
else rc=1; echo "      row-set guard: rows '$rs_rows' (want '200 300', unmoved) temp-left=$rs_tmp out '$(tr '\n' '|' < "$RS/out" 2>/dev/null | head -c 240)'"; fi
ck "the ROW-SET guard REFUSES the write when the product file's rows differ from what was read (nothing written, no temp)" $rc
# D) AN ABSENT product file is the documented unmet-floor case: nothing is CREATED (that would
#    manufacture product work from a classification this pass did not make).
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '200\n300\n' > "$PQ/o/.pool"
rm -f "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log4" 2>&1
if [ ! -e "$PQ/o/candidates.product.txt" ] && [ ! -e "$PQ/o/.product.follow" ]; then rc=0
else rc=1; echo "      an absent product file was CREATED (or left a temp behind): $(ls -a "$PQ/o" | tr '\n' ' ')"; fi
ck "an ABSENT product queue is left absent — the follow invents no product work and leaves no temp file" $rc
# D2) AN UNREADABLE PRODUCT PATH IS NAMED, NOT SILENT (review P3, cycle 8). Absent means "no split ever
#     ran here"; a DIRECTORY on that path means the floor really is reading something this pass could not
#     — and saying nothing about it is how a stale floor head becomes invisible. The pair discriminates:
#     D above (absent) must be SILENT, D2 (unreadable) must say it could not be re-sequenced.
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '200\n300\n' > "$PQ/o/.pool"
rm -f "$PQ/o/candidates.product.txt"
mkdir -p "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive.sh "$PQ/o" ) > "$PQ/log5" 2>&1
if [ -d "$PQ/o/candidates.product.txt" ] && grep -q 'not a readable regular file' "$PQ/log5" 2>/dev/null \
   && ! grep -q 'not a readable regular file' "$PQ/log4" 2>/dev/null; then rc=0
else rc=1; echo "      unreadable product path: log '$(tr '\n' '|' < "$PQ/log5" 2>/dev/null | head -c 240)'; absent case said it too: $(grep -c 'not a readable regular file' "$PQ/log4" 2>/dev/null)"; fi
ck "an UNREADABLE product queue is NAMED (and an ABSENT one stays silent) — the floor head is never left stale in silence" $rc
rmdir "$PQ/o/candidates.product.txt" 2>/dev/null || true
# 12-y) THE COUNT READ-BACK'S POLARITY (review P2 + P3, cycle 9). `.queue-rank` is written by
#        `rank_queue_by_pool` and read back after the install; between those two moments a CONCURRENT pass
#        deletes it (its entry does `rm -f "$o/.queue-rank"`) — reachable, because the refresh lock is
#        cleared by age and by the spawn-failure arms. A shimmed `mv` performs the real install and then
#        models the race, so the code under test is untouched.
count_race() {  # <name> <shim-body> -> sets CROUT / CRR (log, rc) for a real reorder of a 2-row queue
  local d="$TMP/count-$1"
  rm -rf "$d"; mkdir -p "$d/o" "$d/bin"
  printf '300\n200\n' > "$d/o/.pool"
  printf '200\n300\n' > "$d/o/candidates.txt"
  cat > "$d/bin/mv" <<SHIM
#!/usr/bin/env bash
$2
exec /usr/bin/mv "\$@"
SHIM
  chmod +x "$d/bin/mv"
  { echo 'QUEUE_ORDER_STATE=""'; cat "$FNS"; printf 'queue_order_from_pool "$1"\nexit $?\n'; } > "$d/drive.sh"
  ( cd "$d" && HOME="$d" PATH="$d/bin:$PATH" QRO="$d/o" bash drive.sh "$d/o" ) > "$d/out" 2>&1
  CRR=$?
  CROUT="$(cat "$d/out" 2>/dev/null)"
  CRROWS="$(tr '\n' ' ' < "$d/o/candidates.txt" 2>/dev/null | sed 's/ *$//')"
}
count_race gone 'rm -f "$QRO/.queue-rank" 2>/dev/null || true'
if [ "$CRR" -ne 0 ] && [ "$CRROWS" = "300 200" ] && printf '%s' "$CROUT" | grep -q 'priority-unreadable' \
   && ! printf '%s' "$CROUT" | grep -q 'the queue is EMPTY'; then rc=0
else rc=1; echo "      count file GONE: rc=$CRR rows='$CRROWS' out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 240)' (want rc!=0, rows installed, priority-unreadable, NOT 'EMPTY')"; fi
ck "a count file that VANISHES between the reorder and the read-back is UNREADABLE, not a measured EMPTY queue" $rc
count_race bad 'printf "x 2 -\n" > "$QRO/.queue-rank"'
if [ "$CRR" -ne 0 ] && printf '%s' "$CROUT" | grep -q 'priority-unreadable' \
   && ! printf '%s' "$CROUT" | grep -q 'the queue is EMPTY'; then rc=0
else rc=1; echo "      malformed count: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 240)' (want priority-unreadable, NOT 'EMPTY')"; fi
ck "a MALFORMED count field is refused by the strict re-parse, never laundered to zero and read as EMPTY" $rc
count_race good 'true'
if [ "$CRR" -eq 0 ] && printf '%s' "$CROUT" | grep -q 'severity-first from the pool'; then rc=0
else rc=1; echo "      positive pair: rc=$CRR out '$(printf '%s' "$CROUT" | tr '\n' '|' | head -c 240)' (the three fixtures above must not pass because the drive is broken)"; fi
ck "positive pair: with the count file intact the same drive reports 'severity-first from the pool'" $rc
# 12a) NON-VACUITY by MUTATION: make `product_queue_follow` a no-op (`return 0` as its first statement)
#      and the stale-case assertion must RED — the product file stays a pass behind.
MUT_NOFOLLOW="$TMP/fns-nofollow.sh"
sed '/^product_queue_follow() {$/a\  return 0' "$FNS" > "$MUT_NOFOLLOW"
if awk '/^product_queue_follow\(\) \{/{getline; if ($0 ~ /return 0/) found=1} END{exit !found}' "$MUT_NOFOLLOW"; then rc=0
else rc=1; echo "      the no-op mutation did not apply — sed anchor drifted"; fi
ck "the no-op mutation applied to the extracted product_queue_follow (a \`return 0\` as its first statement)" $rc
{
  echo 'QUEUE_ORDER_STATE=""'
  cat "$MUT_NOFOLLOW"
  printf 'queue_order_from_pool "$1"\nproduct_queue_follow "$1"\n'
} > "$PQ/drive-mut.sh"
printf '200\n300\n' > "$PQ/o/candidates.txt"
printf '300\n200\n' > "$PQ/o/.pool"
printf '200\n300\n' > "$PQ/o/candidates.product.txt"
( cd "$PQ" && HOME="$PQ" bash drive-mut.sh "$PQ/o" ) > "$PQ/mutlog" 2>&1
if [ "$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" | sed 's/ *$//')" = "200 300" ] \
   && [ "$(floor_head "$PQ/o/candidates.product.txt" "$PQ/o/candidates.txt")" = "200" ]; then rc=0
else
  mut_prod="$(tr '\n' ' ' < "$PQ/o/candidates.product.txt" | sed 's/ *$//')"
  rc=1; echo "      the NO-OP mutant still moved the product file to '$mut_prod' — check 12 proves nothing"
fi
ck "non-vacuity: with product_queue_follow disabled the floor's head stays on the stale row ('200'), which is what check 12 reds on" $rc

echo "── rank-queue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
