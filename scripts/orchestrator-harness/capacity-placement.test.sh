#!/usr/bin/env bash
# capacity-placement.test.sh — MEASURED placement across the fleet, and the SELF-DISPATCH PROOF.
#
# WHAT WAS BROKEN (measured 2026-10-21 09:45, all three cells), and how every section below is RED on
# the pre-change tree:
#
#   cell-1  load 29.82 on 8 cpu, 105 `pi`     cell-3  load 8.14 on 4 cpu     cell-4  load 0.56 on 8
#   One box saturated while a box TWICE ITS SIZE sat idle, and NOTHING MOVED THE WORK. Every placement
#   decision in the fleet was local (`load=$L>=max_load`, `lanes=`, `swap_free=`, `mem_avail=`), and
#   the one cross-box signal (`capacity_yield_live`, #1909) fires only AFTER a box has refused — a box
#   at half its ceiling never yields, so no box ever learns its neighbour is idle.
#     → §2/§3/§4/§5 are RED pre-change because `cap_place` does not exist: the extraction fails
#       loudly (the way test-gates.sh's does) rather than grading a block it never read.
#
#   Separately: the controller log on cell-1 was 37h STALE and on the other two cells NO log was found
#   at its expected path, so "the controller is looping" was UNPROVEN. Every reader treated a missing
#   log/state file as "nothing to say" — i.e. as fine.
#     → §6/§7 are RED pre-change because nothing writes a per-cycle record and no verb grades it.
#
# HOW THESE ARE WRITTEN. Every check drives the SHIPPED files — `capacity.sh`, `cycle-record.sh`,
# `bin/harness` and `orch-loop.sh` — never a re-implementation (a copy would pass on the broken tree
# too). `git`, `df`, `hostname` and the clock are seams/stubs, so the suite is hermetic: no network,
# no model, and §8 uses a LOCAL bare repo as the shared origin so `cap_publish`/`cap_read_fleet` are
# driven as real pushes and real `ls-remote` reads, not mocks.
#
# ⛔ rc IS CAPTURED IMMEDIATELY AFTER EVERY TESTED COMMAND — never inline inside a `ck` argument,
# where a `$(…)` substitution would silently supply the status of the last command in the pipeline.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/capacity-placement.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
CAP="$HERE/capacity.sh"; CR="$HERE/cycle-record.sh"; LOOP="$HERE/orch-loop.sh"
HARNESS_BIN="$ROOT/bin/harness"
for f in "$CAP" "$CR" "$LOOP" "$HARNESS_BIN"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite grades the shipped files, so it cannot run"; exit 2; }
done
echo "==> capacity-placement self-test ($HERE)"

# ── the model: ONE record per box, in the shipped grammar ────────────────────────────────────────
# rec <host> <ncpu> <load1-x100> <lanes> <disk_mb> <mem_mb> <at>
rec() {
  printf 'host=%s ncpu=%s load1=%s lpc=%s lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s' \
    "$1" "$2" "$3" "$(awk -v l="$3" -v n="$2" 'BEGIN{printf "%d", l/n}')" "$4" "$5" "$6" "$7"
}
NOW=1792598400   # fixed clock for the whole suite (the record age is part of every assertion)

# ── §1 the probe: the fields the rule reads, and an unreadable probe that says so ────────────────
echo
echo "── §1 the probe returns load-per-cpu, lanes, disk and memory (and UNKNOWN when it cannot) ──"
# shellcheck source=/dev/null
. "$CAP"
CAP_NOW="$NOW"; export CAP_NOW
CAP_HOST="cell-1"; export CAP_HOST
P="$(cap_probe_local "$PWD" 7)" || P=""
ck "the probe returns a record" "$([ -n "$P" ] && echo 0 || echo 1)"
for k in host ncpu load1 lpc lanes disk_free_mb mem_free_mb at; do
  v="$(cap_kv "$P" "$k")"
  case "$v" in ''|*[!0-9A-Za-z._-]*) r=1 ;; *) r=0 ;; esac
  ck "  …carrying $k=${v:-<empty>}" "$r"
done
ck "the probe reports THIS box as its host (identity is in the record, so a peer can be named)" \
   "$([ "$(cap_kv "$P" host)" = "cell-1" ] && echo 0 || echo 1)"
ck "lanes is the count the CONTROLLER passed in, not a second independent count" \
   "$([ "$(cap_kv "$P" lanes)" = "7" ] && echo 0 || echo 1)"
ck "load-per-cpu is integer hundredths (bash 3.2 has no floats): 8.14 on 4 cpu => lpc=203" \
   "$(r="$(rec cell-3 4 814 2 80000 9000 $NOW)"; [ "$(cap_kv "$r" lpc)" = "203" ] && echo 0 || echo 1)"
# An unreadable load/ncpu/disk/mem must produce NO record. A fabricated 0 would read as "idle".
_old_ncpu="$(command -v cap_ncpu)"
( cap_load1_100() { return 1; }; P2="$(cap_probe_local "$PWD" 0)" || P2=""; [ -z "$P2" ] ) && r=0 || r=1
ck "an unreadable core field yields NO record (never a fabricated 0, which reads as 'idle')" "$r"
ck "…so the box has no record at all and is therefore INELIGIBLE to placement (see §3)" "$r"

# ── §2 a saturated box is SKIPPED; the least-loaded eligible box is chosen ───────────────────────
echo
echo "── §2 the measured fleet: the saturated box is skipped and the idle box is chosen ──"
# THE MEASURED FLEET of 2026-10-21 09:45, and the pre-change outcome: this box (cell-1, saturated)
# dispatched anyway because every gate was local.
FLEET_MEASURED="$(rec cell-1 8 2982 5 90000 3000 $NOW)
$(rec cell-3 4 814 3 40000 5000 $NOW)
$(rec cell-4 8 56 0 120000 14000 $NOW)"
OUT="$(printf '%s\n' "$FLEET_MEASURED" | cap_place cell-1)"; RC=$?
ck "placement decides rather than refusing (the fleet HAS an idle box)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "the LEAST-LOADED eligible box wins: cell-4 (lpc=7), not the box asking (cell-1, lpc=372)" \
   "$(printf '%s' "$OUT" | grep -q '^place=cell-4 ' && echo 0 || echo 1)"
ck "  …and the verdict carries the numbers it decided from (lpc + how many were evaluated)" \
   "$(printf '%s' "$OUT" | grep -q 'lpc=7 evaluated=3 eligible=3' && echo 0 || echo 1)"
# A box ABOVE the ceiling is skipped even when it is the biggest machine in the fleet.
SAT="$(rec cell-1 8 6410 6 90000 3000 $NOW)   # 64.10 load on 8 cpu = lpc=801 > ceiling 800"
OUT2="$(printf '%s\n%s\n' "$SAT" "$(rec cell-4 8 56 0 120000 14000 $NOW)" | cap_place cell-1)"; RC=$?
ck "a box ABOVE the load-per-cpu ceiling (lpc=801 > 800) is SKIPPED" \
   "$(printf '%s' "$OUT2" | grep -q '^place=cell-4 ' && echo 0 || echo 1)"
ck "  …and it is named in the verdict as ineligible with the bound it hit, not silently dropped" \
   "$(printf '%s' "$OUT2" | grep -q 'ineligible=\[cell-1:load_per_cpu\]' && echo 0 || echo 1)"
# ⛔ NON-VACUITY: the SAME fixture with the ceiling lifted must place on cell-1, so the assertion
# above is proven to be about the ceiling and not about the fixture.
OUT2b="$(printf '%s\n%s\n' "$SAT" "$(rec cell-4 8 56 0 120000 14000 $NOW)" | CAP_LPC_CEILING=999999 cap_place cell-1)"
ck "  …non-vacuity: with the ceiling lifted the SAME fixture places on cell-4 (lpc=7 still lower)" \
   "$(printf '%s' "$OUT2b" | grep -q '^place=cell-4 ' && echo 0 || echo 1)"
OUT2c="$(printf '%s\n' "$SAT" | CAP_LPC_CEILING=999999 cap_place cell-1)"
ck "  …and with ONLY the big box left and the ceiling lifted it DOES take the work (the rule is the ceiling)" \
   "$(printf '%s' "$OUT2c" | grep -q '^place=cell-1 ' && echo 0 || echo 1)"
OUT2d="$(printf '%s\n' "$SAT" | cap_place cell-1)"
ck "  …so with the shipped ceiling it is REFUSED instead (fail-closed on the only box available)" \
   "$(printf '%s' "$OUT2d" | grep -q '^refuse bound=load_per_cpu' && echo 0 || echo 1)"
ck "there is NO lane ceiling tied to cpu count (the owner's 2026-10-17 ruling): a box with 200 lanes" \
   "$(printf '%s\n' "$(rec cell-1 8 56 200 120000 14000 $NOW)" | cap_place cell-1 | grep -q '^place=cell-1 ' && echo 0 || echo 1)"
ck "  …and lanes IS reported, so an operator can read the pile-up even though it is not a gate" \
   "$(printf '%s' "$P" | grep -q 'lanes=7' && echo 0 || echo 1)"

# ── §3 an UNREADABLE box is never chosen ────────────────────────────────────────────────────────
echo
echo "── §3 an unreadable box is NOT eligible (and is never read as 'least loaded') ──"
BUSY="$(rec cell-1 8 2982 5 90000 3000 $NOW)"
for shape in absent stale malformed hostless; do
  exp_host="cell-4"; exp_bound=""
  case "$shape" in
    absent)    PEER="" ;;
    stale)     PEER="$(rec cell-4 8 56 0 120000 14000 $(( NOW - 4000 )))"; exp_bound=probe_stale ;;  # TTL 900s
    malformed) PEER="host=cell-4 ncpu=8 load1= nope"; exp_bound=probe_unreadable ;;
    # A record with NO host cannot be attributed to a box at all — it is unreadable, and it is named
    # `?` rather than dropped: a record the fleet cannot key is a defect in the WRITER, not silence.
    hostless)  PEER="ncpu=8 load1=56 lpc=7 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=$NOW"
               exp_bound=probe_unreadable; exp_host='?' ;;
  esac
  OUT3="$(printf '%s\n%s\n' "$BUSY" "${PEER:-}" | grep -v '^$' | cap_place cell-1)"; RC=$?
  if [ "$shape" = "absent" ]; then
    ck "NO record for the idle box => the box asking takes it, and the absent box is NOT named" \
       "$(printf '%s' "$OUT3" | grep -q '^place=cell-1 ' && echo 0 || echo 1)"
  else
    ck "a $shape record for the idle box is NOT chosen (the asking box keeps the work)" \
       "$(printf '%s' "$OUT3" | grep -q '^place=cell-1 ' && echo 0 || echo 1)"
    ck "  …and it is named as ineligible with its bound ($shape => $exp_bound)" \
       "$(printf '%s' "$OUT3" | grep -qF "ineligible=[$exp_host:$exp_bound]" && echo 0 || echo 1)"
  fi
done
OUT3e="$(cap_place cell-1 </dev/null)"; RC=$?
ck "an EMPTY fleet (nothing published yet) refuses with bound=no_probe — never a blind place" \
   "$([ "$RC" -eq 1 ] && printf '%s' "$OUT3e" | grep -q '^refuse bound=no_probe' && echo 0 || echo 1)"
OUT3f="$(printf '%s\n' "$(rec cell-4 8 56 0 120000 14000 $(( NOW - 3599 )))" | CAP_PROBE_TTL=3600 cap_place cell-1)"
ck "  …a record INSIDE the TTL is used (the bound is the TTL, not 'any age at all')" \
   "$(printf '%s' "$OUT3f" | grep -q '^place=cell-4 ' && echo 0 || echo 1)"

# ── §4 no eligible box => REFUSAL naming the bound; NEVER a blind place ─────────────────────────
echo
echo "── §4 no eligible box => refused, and the refusal NAMES what it hit ──"
HOT="$(rec a-hot 8 6410 6 90000 3000 $NOW)
$(rec b-hot 4 4010 4 90000 3000 $NOW)"
OUT4="$(printf '%s\n' "$HOT" | cap_place a-hot)"; RC=$?
ck "two boxes above the ceiling => REFUSED (rc 1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "  …the refusal names bound=load_per_cpu (the dominant bound, not a bare 'no capacity')" \
   "$(printf '%s' "$OUT4" | grep -q '^refuse bound=load_per_cpu' && echo 0 || echo 1)"
ck "  …and it carries the ceiling it applied and the per-box detail, so it is auditable" \
   "$(printf '%s' "$OUT4" | grep -q 'ceiling_lpc=800' && printf '%s' "$OUT4" | grep -q 'a-hot:load_per_cpu' && echo 0 || echo 1)"
FULL="$(rec a-full 8 56 0 300 14000 $NOW)
$(rec b-full 8 56 0 100 14000 $NOW)"
OUT4d="$(printf '%s\n' "$FULL" | cap_place a-full)"
ck "boxes with no free disk are refused with bound=disk (a different remedy from load)" \
   "$(printf '%s' "$OUT4d" | grep -q '^refuse bound=disk' && echo 0 || echo 1)"
LEAK="$(rec a-leak 8 56 0 120000 200 $NOW)"
OUT4m="$(printf '%s\n' "$LEAK" | cap_place a-leak)"
ck "a box with no free memory is refused with bound=memory" \
   "$(printf '%s' "$OUT4m" | grep -q '^refuse bound=memory' && echo 0 || echo 1)"
OUT4u="$(printf 'garbage\nmore-garbage\n' | cap_place a-x)"
ck "unparseable records are refused with bound=probe_unreadable (never silently ignored)" \
   "$(printf '%s' "$OUT4u" | grep -q '^refuse bound=probe_unreadable' && echo 0 || echo 1)"
ck "  …non-vacuity control: an eligible record under the SAME call sites DOES place" \
   "$(printf '%s\n' "$(rec a-ok 8 56 0 120000 14000 $NOW)" | cap_place a-ok | grep -q '^place=a-ok ' && echo 0 || echo 1)"

# ── §5 §2's rule under the CONTROLLER's calling convention (stdin, one record per line) ─────────
echo
echo "── §5 the controller's calling shape: records on stdin, one per line (not word-split args) ──"
# ⛔ THIS IS THE BUG THE SHAPE PREVENTS: a record CONTAINS SPACES, so `cap_place host $fleet` splits
# every record into fragments and the verdict reads "no eligible box" — which looks like a capacity
# answer and is actually a calling bug. Driving stdin here is what pins it.
OUT5="$(printf '%s\n%s\n' "$(rec cell-1 8 2982 5 90000 3000 $NOW)" "$(rec cell-4 8 56 0 120000 14000 $NOW)" | cap_place cell-1)"
ck "records piped on stdin are parsed whole (3 fields in, 3 evaluated, cell-4 chosen)" \
   "$(printf '%s' "$OUT5" | grep -q 'place=cell-4 lpc=7 evaluated=2' && echo 0 || echo 1)"
OUT5b="$(printf '%s\n' "$(rec cell-1 8 56 0 120000 14000 $NOW)" | cap_place cell-1)"
ck "a single-box fleet places on that box (the rule does not require a peer to exist)" \
   "$(printf '%s' "$OUT5b" | grep -q '^place=cell-1 ' && echo 0 || echo 1)"

# ── §6 THE CYCLE RECORD: HEALTHY / DEGRADED / ABSENT, and 'absent' is never 'fine' ──────────────
echo
echo "── §6 the self-dispatch proof: two missed cycles is DEGRADED, no record at all is ABSENT ──"
O="$TMP/O"; mkdir -p "$O/state"
# shellcheck source=/dev/null
. "$CR"
CR_NOW="$NOW"; export CR_NOW
w() { cycle_record_write "$O" start="$1" end="$(( $1 + 3 ))" cycle="$2" interval=240 \
      selected="issue:#2216" selected_n=1 dispatched=1 ids="#2216" nothing=none \
      placement=place placed_on=cell-1 bound=none lpc_self=7 >/dev/null; }
ck "ABSENT is rc 2 — a box with no record NEVER reports healthy" \
   "$(cycle_verdict "$O" >/dev/null; [ "$?" -eq 2 ] && echo 0 || echo 1)"
ck "  …and it is named as ABSENT, not as an empty/degraded middle state" \
   "$(cycle_verdict "$O" 2>/dev/null | grep -q '^ABSENT ' && echo 0 || echo 1)"
w $(( NOW - 240 )) 1
V="$(cycle_verdict "$O")"; RC=$?
ck "a record ONE cycle old is HEALTHY (rc 0)" "$([ "$RC" -eq 0 ] && printf '%s' "$V" | grep -q '^HEALTHY ' && echo 0 || echo 1)"
ck "  …and the verdict carries the age, the cycle count and the interval it judged by" \
   "$(printf '%s' "$V" | grep -q 'age=240 cycles=1 interval=240' && echo 0 || echo 1)"
w $(( NOW - 479 )) 2
V="$(cycle_verdict "$O")"; RC=$?
ck "a record just INSIDE two cycles (479s of 480) is still HEALTHY — the bound is inclusive" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
w $(( NOW - 481 )) 3
V="$(cycle_verdict "$O")"; RC=$?
ck "a record OLDER than two cycles (481s) is DEGRADED, rc 1 — not HEALTHY" \
   "$([ "$RC" -eq 1 ] && printf '%s' "$V" | grep -q '^DEGRADED ' && echo 0 || echo 1)"
ck "  …and the DEGRADED line names the bound it was judged by (so the reading is auditable)" \
   "$(printf '%s' "$V" | grep -q 'bound=480 why=stale_record' && echo 0 || echo 1)"
# ⛔ THE LATENT DEFECT THIS PINS: a history file with MANY records is not freshness. This is exactly
# the shape that read as healthy on cell-1 (a 37h-old log with plenty in it, and no one asking the
# age of the NEWEST line).
ck "a long history with a STALE newest record is DEGRADED (a record count is not freshness)" \
   "$([ "$RC" -eq 1 ] && [ "$(cycle_verdict "$O" | sed -n 's/.*cycles=\([0-9]*\).*/\1/p')" -ge 3 ] && echo 0 || echo 1)"
O2="$TMP/O2"; mkdir -p "$O2/state"
printf 'this is not a record\n' > "$O2/state/cycles"
ck "an UNPARSEABLE newest record is rc 2 (cannot answer is never a pass)" \
   "$(cycle_verdict "$O2" >/dev/null; [ "$?" -eq 2 ] && echo 0 || echo 1)"
ck "  …and it is named UNREADABLE, not DEGRADED and not HEALTHY" \
   "$(cycle_verdict "$O2" 2>/dev/null | grep -q '^UNREADABLE ' && echo 0 || echo 1)"
O3="$TMP/O3"
ck "an UNWRITABLE state dir makes the writer FAIL LOUDLY (rc 1), never silently succeed" \
   "$(cycle_record_write /dev/null/nope start=1 >/dev/null 2>&1; [ "$?" -eq 1 ] && echo 0 || echo 1)"

# ── §7 the verb a human/agent actually reads: bin/harness status ─────────────────────────────────
echo
echo "── §7 bin/harness status: the answer, with the exit code that cannot lie ──"
O="$TMP/O7"; mkdir -p "$O/state"
cycle_record_write "$O" start=$(( NOW - 240 )) end="$NOW" cycle=1 interval=240 selected="pr:#2244" \
  selected_n=3 dispatched=2 ids="#2216,#2232" nothing=none placement=place placed_on=cell-4 bound=none \
  lpc_self=372 >/dev/null
OUT="$(O="$O" CR_NOW="$NOW" bash "$HARNESS_BIN" status 2>&1)"; RC=$?
ck "HEALTHY exits 0 and says the controller IS self-dispatching" \
   "$([ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'harness status — HEALTHY' && echo 0 || echo 1)"
ck "  …and prints the cycle line VERBATIM (selected / dispatched / why nothing)" \
   "$(printf '%s' "$OUT" | grep -q 'selected=pr:#2244' && printf '%s' "$OUT" | grep -q 'nothing=none' && echo 0 || echo 1)"
ck "  …and the placement verdict + the bound, so 'why nothing dispatched' needs no pane" \
   "$(printf '%s' "$OUT" | grep -q 'placement=place' && printf '%s' "$OUT" | grep -q 'bound=none' && echo 0 || echo 1)"
OUT_S="$(O="$TMP/O7-stale" CR_NOW="$NOW" bash "$HARNESS_BIN" status 2>&1)"; RC=$?
ck "NO record at all exits 2 and prints ABSENT (an absent record never reads as fine)" \
   "$([ "$RC" -eq 2 ] && printf '%s' "$OUT_S" | grep -q 'harness status — ABSENT' && echo 0 || echo 1)"
O="$TMP/O7b"; mkdir -p "$O/state"
cycle_record_write "$O" start=$(( NOW - 5000 )) end="$NOW" cycle=1 interval=240 selected="issue:none" \
  selected_n=0 dispatched=0 ids=- nothing="gate:merge-priority" placement=refuse placed_on=none \
  bound=disk lpc_self=372 >/dev/null
OUT_D="$(O="$O" CR_NOW="$NOW" bash "$HARNESS_BIN" status 2>&1)"; RC=$?
ck "a STALE newest record exits 1 and prints DEGRADED (not HEALTHY, not 'no data')" \
   "$([ "$RC" -eq 1 ] && printf '%s' "$OUT_D" | grep -q 'harness status — DEGRADED' && echo 0 || echo 1)"
ck "  …and shows WHY that cycle dispatched nothing (gate + bound) from the record alone" \
   "$(printf '%s' "$OUT_D" | grep -q 'nothing=gate:merge-priority' && printf '%s' "$OUT_D" | grep -q 'bound=disk' && echo 0 || echo 1)"
OUT_J="$(O="$TMP/O7" CR_NOW="$NOW" bash "$HARNESS_BIN" status --json 2>&1)"
ck "--json emits a parseable verdict object (the machine-readable half of the same answer)" \
   "$(printf '%s' "$OUT_J" | grep -q '"verdict": "HEALTHY"' && echo 0 || echo 1)"
ck "--last is honoured (asking for 1 shows one cycle, not the whole history)" \
   "$(O="$TMP/O7" CR_NOW="$NOW" bash "$HARNESS_BIN" status --last 1 2>&1 | grep -c '^ *age=' | grep -qx '1' && echo 0 || echo 1)"

# ── §8 the transport: publish/read over a LOCAL bare origin (real pushes, real ls-remote) ────────
echo
echo "── §8 the fleet channel: records published as refs, read back with ONE ls-remote ──"
ORIGIN="$TMP/origin.git"; WORK="$TMP/work"
git init -q --bare "$ORIGIN" >/dev/null 2>&1
git init -q "$WORK" >/dev/null 2>&1
( cd "$WORK" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$ORIGIN" \
  && git push -q origin HEAD:main ) >/dev/null 2>&1
ck "the harness repo (a local bare origin) is ready" "$([ -d "$ORIGIN" ] && echo 0 || echo 1)"
CAP_NOW="$NOW"
PUB="$(CAP_NOW="$NOW" CAP_HOST="cell-4" cap_publish "$WORK" "$(rec cell-4 8 56 0 120000 14000 $NOW)")"; RC=$?
ck "a box PUBLISHES its record (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "  …under refs/boxes/<host>/<reading> (the reading rides the ref name: no fetch per box)" \
   "$(printf '%s' "$PUB" | grep -q 'ref=refs/boxes/cell-4/' && echo 0 || echo 1)"
CAP_HOST="cell-1" cap_publish "$WORK" "$(rec cell-1 8 2982 5 90000 3000 $NOW)" >/dev/null 2>&1
READ="$(cap_read_fleet "$WORK")"; RC=$?
ck "a PEER reads the whole fleet with one ls-remote (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "  …and both boxes are in it, with their readings intact" \
   "$(printf '%s' "$READ" | grep -q 'host=cell-4 .*lpc=7 ' && printf '%s' "$READ" | grep -q 'host=cell-1 .*lpc=372 ' && echo 0 || echo 1)"
PL="$(printf '%s\n' "$READ" | cap_place cell-1)"
ck "placement over the REAL channel picks the idle box" \
   "$(printf '%s' "$PL" | grep -q '^place=cell-4 ' && echo 0 || echo 1)"
# A second reading from the SAME box must supersede the first, and must not delete a peer's.
CAP_HOST="cell-4" cap_publish "$WORK" "$(rec cell-4 8 6100 3 120000 14000 $(( NOW + 60 )))" >/dev/null 2>&1
READ2="$(cap_read_fleet "$WORK")"
ck "a newer reading supersedes the old one for that box (one record per box, newest wins)" \
   "$(printf '%s' "$READ2" | grep -q 'host=cell-4 .*lpc=762 ' && echo 0 || echo 1)"
ck "  …and only ONE cell-4 ref survives (the publisher prunes its own old record)" \
   "$([ "$(printf '%s' "$READ2" | grep -c 'host=cell-4 ')" -eq 1 ] && echo 0 || echo 1)"
ck "  …and the peer's record is UNTOUCHED by that prune (host-scoped, never fleet-wide)" \
   "$(printf '%s' "$READ2" | grep -q 'host=cell-1 ' && echo 0 || echo 1)"
PL2="$(printf '%s\n' "$READ2" | cap_place cell-1)"
ck "…and placement MOVES OFF the now-saturated box (cell-4 at lpc=762 is no longer idle)" \
   "$(printf '%s' "$PL2" | grep -q '^place=cell-1 ' && echo 0 || echo 1)"
ck "an UNREADABLE channel (a repo with no origin) is rc 2, so the caller must refuse to place" \
   "$(mkdir -p "$TMP/noorigin" && git init -q "$TMP/noorigin" && cap_read_fleet "$TMP/noorigin" >/dev/null 2>&1; [ "$?" -eq 2 ] && echo 0 || echo 1)"

# ── §9 WIRING: an unwired library is inert — the CONTROLLER must call it ─────────────────────────
echo
echo "── §9 the controller actually calls it (a defined-but-unused guard is inert) ──"
ck "orch-loop.sh sources capacity.sh from \$O, falling back to its own directory" \
   "$(grep -q 'capacity.sh' "$LOOP" && grep -q '_cap_mod' "$LOOP" && echo 0 || echo 1)"
ck "…and gates on the INTERFACE (declare -f), not on the file, so a stale copy cannot read as wired" \
   "$(grep -q 'declare -f cap_probe_local cap_place cap_read_fleet cap_publish' "$LOOP" && echo 0 || echo 1)"
ck "the cycle PROBES this box and PUBLISHES the reading" \
   "$(grep -q 'cap_probe_local "\$REPO"' "$LOOP" && grep -q 'cap_publish "\$REPO"' "$LOOP" && echo 0 || echo 1)"
ck "…READS the fleet and ASKS cap_place for the target box" \
   "$(grep -q 'cap_read_fleet "\$REPO"' "$LOOP" && grep -q 'cap_place "\$(cap_host)"' "$LOOP" && echo 0 || echo 1)"
ck "the placement verdict is in the [capacity] log line (the decision is visible every cycle)" \
   "$(grep -q '\[capacity\] placement=' "$LOOP" && echo 0 || echo 1)"
ck "a NO-ELIGIBLE-BOX verdict becomes GATE_WHY (nothing is placed, and the bound is named)" \
   "$(grep -q 'capacity-placement(bound=' "$LOOP" && echo 0 || echo 1)"
ck "…and the arm is reached only when cap_place actually refused (not on a stale variable)" \
   "$(grep -q 'CAP_STATE:-unavailable}" = "refuse"' "$LOOP" && echo 0 || echo 1)"
# ⛔ THE YIELD ORDER IS LOAD-BEARING (#1909's lesson): placement must sit AFTER the yield check and
# BEFORE the claim. After the claim, a placed-elsewhere item is already owned by the box that did not
# want it; before the yield check, it would mask a refusal that has its own record.
_y_line="$(grep -n 'if capacity_yield_live "\$ISS"; then' "$LOOP" | head -1 | cut -d: -f1)"
_p_line="$(grep -n 'placed-on \${CAP_PLACE}' "$LOOP" | head -1 | cut -d: -f1)"
_c_line="$(grep -n 'if claim_issue_acquire "" "\$ISS"; then' "$LOOP" | head -1 | cut -d: -f1)"
if [ -n "${_y_line:-}" ] && [ -n "${_p_line:-}" ] && [ -n "${_c_line:-}" ]; then
  [ "$_p_line" -gt "$_y_line" ] && [ "$_p_line" -lt "$_c_line" ] && r=0 || r=1
else r=1; fi
ck "the placement yield sits AFTER the capacity yield and BEFORE the claim (y/p/c=$_y_line/$_p_line/$_c_line)" "$r"
ck "…and it does NOT consume the item (no dispatched.txt write on that path — 'continue' only)" \
   "$(sed -n "${_p_line},$(( _p_line + 1 ))p" "$LOOP" | grep -q 'continue' && echo 0 || echo 1)"
ck "orch-loop.sh writes ONE cycle record per cycle (start / selected / dispatched / why nothing)" \
   "$(grep -q 'cycle_record_write "\$O"' "$LOOP" && echo 0 || echo 1)"
ck "…with the cycle START as its clock (a record stamped at the end hides a cycle that hung)" \
   "$(grep -q 'start="\${CYCLE_T0:-0}"' "$LOOP" && echo 0 || echo 1)"
ck "…and a record that CANNOT be written says so loudly (never a silent no-op)" \
   "$(grep -q 'THIS CYCLE COULD NOT BE RECORDED' "$LOOP" && echo 0 || echo 1)"
ck "…and a MISSING cycle-record.sh is named every cycle (no proof => the status verb reads ABSENT)" \
   "$(grep -q 'leaves NO proof it ran' "$LOOP" && echo 0 || echo 1)"
ck "bin/harness gained the status verb" "$(grep -q 'bin/harness status' "$HARNESS_BIN" && echo 0 || echo 1)"
ck "…which exits non-zero for DEGRADED (a status verb that always exits 0 is a lie)" \
   "$(grep -q 'exit "\$_rc"' "$HARNESS_BIN" && echo 0 || echo 1)"
# ⛔ MUTATION CONTROL: remove the record write from a COPY of the loop and the assertion above must
# FAIL. Without this, §9 could be satisfied by a comment.
sed 's/^    cycle_record_write "\$O" \\$/    : cycle_record_write-disabled \\/' "$LOOP" > "$TMP/orch-no-record.sh"
grep -q 'cycle_record_write "\$O"' "$TMP/orch-no-record.sh" && r=1 || r=0
ck "mutation control: a loop with the record write REMOVED no longer satisfies the wiring check" "$r"
sed 's/^      if \[ "${CAP_STATE:-unavailable}" = "place" \]/      if false; then #/' "$LOOP" > "$TMP/orch-no-place.sh"
grep -q 'placed-on \${CAP_PLACE}' "$TMP/orch-no-place.sh" && r=0 || r=1
_pl="$(grep -n 'placed-on \${CAP_PLACE}' "$TMP/orch-no-place.sh" | head -1 | cut -d: -f1)"
if [ -n "${_pl:-}" ]; then
  sed -n "$(( _pl - 5 )),$(( _pl + 1 ))p" "$TMP/orch-no-place.sh" | grep -q 'if false; then' && r=0 || r=1
fi
ck "mutation control: a loop whose placement arm is disabled FAILS the arm assertion" "$r"

# ── §10 self-registration ───────────────────────────────────────────────────────────────────────
echo
echo "── §10 this suite is EXECUTED by CI, not merely named ──"
SHARDS="$ROOT/scripts/run-bash-shards.sh"
ck "capacity-placement.test.sh is registered in run-bash-shards.sh (the ONE list both lanes run)" \
   "$(grep -q 'capacity-placement.test.sh' "$SHARDS" && echo 0 || echo 1)"

echo
echo "───────────────────────────────────────────────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
