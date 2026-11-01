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
# ⛔ NO `printf … | grep -q …` ANYWHERE IN THIS SUITE. A quiet grep closes the pipe and the writer
# takes SIGPIPE; under `pipefail` the pipeline's status is then the WRITER's, so the assertion can
# report a false PASS (agent-infra #841/#864, enforced by scripts/check-no-sigpipe-grep.sh). A
# here-string feeds the same bytes with no pipe at all.
q()  { grep -q  -- "$1" <<<"${2:-}"; }
qF() { grep -qF -- "$1" <<<"${2:-}"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/capacity-placement.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
CAP="$HERE/capacity.sh"; CR="$HERE/cycle-record.sh"; LOOP="$HERE/orch-loop.sh"
HARNESS_BIN="$ROOT/bin/harness"
for f in "$CAP" "$CR" "$LOOP" "$HARNESS_BIN"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite grades the shipped files, so it cannot run"; exit 2; }
done
echo "==> capacity-placement self-test ($HERE)"

# ── the model: ONE record per box, in the shipped grammar ────────────────────────────────────────
# rec <host> <ncpu> <load1-x100> <lanes> <disk_mb> <mem_mb> <at>
# …in the shipped grammar INCLUDING the fork fields (agent-infra#2293). The defaults describe a healthy
# box (400 procs against a 15041 ceiling, probe ok), so every arm written before that change keeps the
# meaning it was written with; arms that need a starved box use `recf` explicitly.
BOOT=1700000000   # a fixed boot epoch: one box cannot have two, which is what §12's detector reads
rec() {
  recf "$1" "$2" "$3" "$4" "$5" "$6" "$7" 400 15041 1
}
# recf <host> <ncpu> <load1-x100> <lanes> <disk_mb> <mem_mb> <at> <procs> <procs_max> <fork>
# ⛔ `boxid=` IS PART OF THE SHIPPED RECORD NOW (#2707) and the default here is DERIVED FROM THE HOST,
# so every arm keeps its meaning (one box per fixture host) — while §12 drives the REAL derivation from
# the box's own network identity. A fixture that omitted it would make its box `box_unknown`, which is
# correct behaviour and would silently turn every arm below into a test of that one bound.
recf() {
  printf 'host=%s ncpu=%s load1=%s lpc=%s lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s procs=%s procs_max=%s fork=%s boxid=%s boot=%s' \
    "$1" "$2" "$3" "$(awk -v l="$3" -v n="$2" 'BEGIN{printf "%d", l/n}')" "$4" "$5" "$6" "$7" \
    "$8" "$9" "${10}" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')" "$BOOT"
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
for k in host ncpu load1 lpc lanes disk_free_mb mem_free_mb at procs procs_max fork; do
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
   "$(q '^place=cell-4 ' "$OUT" && echo 0 || echo 1)"
ck "  …and the verdict carries the numbers it decided from (lpc + how many were evaluated)" \
   "$(q 'lpc=7 evaluated=3 eligible=3' "$OUT" && echo 0 || echo 1)"
# A box ABOVE the ceiling is skipped even when it is the biggest machine in the fleet.
SAT="$(rec cell-1 8 6410 6 90000 3000 $NOW)   # 64.10 load on 8 cpu = lpc=801 > ceiling 800"
OUT2="$(printf '%s\n%s\n' "$SAT" "$(rec cell-4 8 56 0 120000 14000 $NOW)" | cap_place cell-1)"; RC=$?
ck "a box ABOVE the load-per-cpu ceiling (lpc=801 > 800) is SKIPPED" \
   "$(q '^place=cell-4 ' "$OUT2" && echo 0 || echo 1)"
ck "  …and it is named in the verdict as ineligible with the bound it hit, not silently dropped" \
   "$(q 'ineligible=\[cell-1:load_per_cpu\]' "$OUT2" && echo 0 || echo 1)"
# ⛔ NON-VACUITY: the SAME fixture with the ceiling lifted must place on cell-1, so the assertion
# above is proven to be about the ceiling and not about the fixture.
OUT2b="$(printf '%s\n%s\n' "$SAT" "$(rec cell-4 8 56 0 120000 14000 $NOW)" | CAP_LPC_CEILING=999999 cap_place cell-1)"
ck "  …non-vacuity: with the ceiling lifted the SAME fixture places on cell-4 (lpc=7 still lower)" \
   "$(q '^place=cell-4 ' "$OUT2b" && echo 0 || echo 1)"
OUT2c="$(printf '%s\n' "$SAT" | CAP_LPC_CEILING=999999 cap_place cell-1)"
ck "  …and with ONLY the big box left and the ceiling lifted it DOES take the work (the rule is the ceiling)" \
   "$(q '^place=cell-1 ' "$OUT2c" && echo 0 || echo 1)"
OUT2d="$(printf '%s\n' "$SAT" | cap_place cell-1)"
ck "  …so with the shipped ceiling it is REFUSED instead (fail-closed on the only box available)" \
   "$(q '^refuse bound=load_per_cpu' "$OUT2d" && echo 0 || echo 1)"
ck "the PREFER-ELSEWHERE line is half the ceiling (4.00 vs 8.00) and both are load-per-cpu" \
   "$(. "$CAP"; [ "$CAP_YIELD_AT_LPC" = "400" ] && [ "$CAP_LPC_CEILING" = "800" ] && echo 0 || echo 1)"
ck "there is NO lane ceiling tied to cpu count (the owner's 2026-10-17 ruling): a box with 200 lanes" \
   "$(printf '%s\n' "$(rec cell-1 8 56 200 120000 14000 $NOW)" | cap_place cell-1 | grep -q '^place=cell-1 ' && echo 0 || echo 1)"
ck "  …and lanes IS reported, so an operator can read the pile-up even though it is not a gate" \
   "$(q 'lanes=7' "$P" && echo 0 || echo 1)"

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
       "$(q '^place=cell-1 ' "$OUT3" && echo 0 || echo 1)"
  else
    ck "a $shape record for the idle box is NOT chosen (the asking box keeps the work)" \
       "$(q '^place=cell-1 ' "$OUT3" && echo 0 || echo 1)"
    _needle="ineligible=[$exp_host:$exp_bound]"
    ck "  …and it is named as ineligible with its bound ($shape => $exp_bound)" \
       "$(qF "$_needle" "$OUT3" && echo 0 || echo 1)"
  fi
done
OUT3e="$(cap_place cell-1 </dev/null)"; RC=$?
ck "an EMPTY fleet (nothing published yet) refuses with bound=no_probe — never a blind place" \
   "$([ "$RC" -eq 1 ] && q '^refuse bound=no_probe' "$OUT3e" && echo 0 || echo 1)"
OUT3f="$(printf '%s\n' "$(rec cell-4 8 56 0 120000 14000 $(( NOW - 3599 )))" | CAP_PROBE_TTL=3600 cap_place cell-1)"
ck "  …a record INSIDE the TTL is used (the bound is the TTL, not 'any age at all')" \
   "$(q '^place=cell-4 ' "$OUT3f" && echo 0 || echo 1)"

# ── §4 no eligible box => REFUSAL naming the bound; NEVER a blind place ─────────────────────────
echo
echo "── §4 no eligible box => refused, and the refusal NAMES what it hit ──"
HOT="$(rec a-hot 8 6410 6 90000 3000 $NOW)
$(rec b-hot 4 4010 4 90000 3000 $NOW)"
OUT4="$(printf '%s\n' "$HOT" | cap_place a-hot)"; RC=$?
ck "two boxes above the ceiling => REFUSED (rc 1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "  …the refusal names bound=load_per_cpu (the dominant bound, not a bare 'no capacity')" \
   "$(q '^refuse bound=load_per_cpu' "$OUT4" && echo 0 || echo 1)"
ck "  …and it carries the ceiling it applied and the per-box detail, so it is auditable" \
   "$(q 'ceiling_lpc=800' "$OUT4" && q 'a-hot:load_per_cpu' "$OUT4" && echo 0 || echo 1)"
FULL="$(rec a-full 8 56 0 300 14000 $NOW)
$(rec b-full 8 56 0 100 14000 $NOW)"
OUT4d="$(printf '%s\n' "$FULL" | cap_place a-full)"
ck "boxes with no free disk are refused with bound=disk (a different remedy from load)" \
   "$(q '^refuse bound=disk' "$OUT4d" && echo 0 || echo 1)"
LEAK="$(rec a-leak 8 56 0 120000 200 $NOW)"
OUT4m="$(printf '%s\n' "$LEAK" | cap_place a-leak)"
ck "a box with no free memory is refused with bound=memory" \
   "$(q '^refuse bound=memory' "$OUT4m" && echo 0 || echo 1)"
OUT4u="$(printf 'garbage\nmore-garbage\n' | cap_place a-x)"
ck "unparseable records are refused with bound=probe_unreadable (never silently ignored)" \
   "$(q '^refuse bound=probe_unreadable' "$OUT4u" && echo 0 || echo 1)"
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
   "$(q 'place=cell-4 lpc=7 evaluated=2' "$OUT5" && echo 0 || echo 1)"
OUT5b="$(printf '%s\n' "$(rec cell-1 8 56 0 120000 14000 $NOW)" | cap_place cell-1)"
ck "a single-box fleet places on that box (the rule does not require a peer to exist)" \
   "$(q '^place=cell-1 ' "$OUT5b" && echo 0 || echo 1)"

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
ck "a record ONE cycle old is HEALTHY (rc 0)" "$([ "$RC" -eq 0 ] && q '^HEALTHY ' "$V" && echo 0 || echo 1)"
ck "  …and the verdict carries the age, the cycle count and the interval it judged by" \
   "$(q 'age=240 cycles=1 interval=240' "$V" && echo 0 || echo 1)"
w $(( NOW - 479 )) 2
V="$(cycle_verdict "$O")"; RC=$?
ck "a record just INSIDE two cycles (479s of 480) is still HEALTHY — the bound is inclusive" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
w $(( NOW - 481 )) 3
V="$(cycle_verdict "$O")"; RC=$?
ck "a record OLDER than two cycles (481s) is DEGRADED, rc 1 — not HEALTHY" \
   "$([ "$RC" -eq 1 ] && q '^DEGRADED ' "$V" && echo 0 || echo 1)"
ck "  …and the DEGRADED line names the bound it was judged by (so the reading is auditable)" \
   "$(q 'bound=480 why=stale_record' "$V" && echo 0 || echo 1)"
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
# ⛔ THE LANDING READ (agent-infra#2320) IS ONE OF `status`'S DIMENSIONS, and it makes TWO external
# calls: `gh --version` and the branch-protection read. Without a stub this section stops being
# hermetic — it would reach GitHub from a unit suite, on whatever `OR` the host happens to export —
# and it would grade the operator's box instead of the fixture. The stub answers both calls.
STUBGH="$TMP/stubgh"; mkdir -p "$STUBGH"
printf '#!/usr/bin/env bash\ncase "$*" in\n  *--version*) printf "gh version 9.9.9 (test-stub)\\n" ;;\n  *protection/required_status_checks*) printf "pipeline-compliance\\n" ;;\n  *) printf "stub: %%s\\n" "$*" >&2; exit 1 ;;\nesac\n' > "$STUBGH/gh"
chmod +x "$STUBGH/gh"
PATH="$STUBGH:$PATH"; export PATH
O="$TMP/O7"; mkdir -p "$O/state"
cycle_record_write "$O" start=$(( NOW - 240 )) end="$NOW" cycle=1 interval=240 selected="pr:#2244" \
  selected_n=3 dispatched=2 ids="#2216,#2232" nothing=none placement=place placed_on=cell-4 bound=none \
  lpc_self=372 >/dev/null
OUT="$(O="$O" CR_NOW="$NOW" bash "$HARNESS_BIN" status 2>&1)"; RC=$?
ck "HEALTHY exits 0 and says the controller IS self-dispatching" \
   "$([ "$RC" -eq 0 ] && q 'harness status — HEALTHY' "$OUT" && echo 0 || echo 1)"
ck "  …and prints the cycle line VERBATIM (selected / dispatched / why nothing)" \
   "$(q 'selected=pr:#2244' "$OUT" && q 'nothing=none' "$OUT" && echo 0 || echo 1)"
ck "  …and the placement verdict + the bound, so 'why nothing dispatched' needs no pane" \
   "$(q 'placement=place' "$OUT" && q 'bound=none' "$OUT" && echo 0 || echo 1)"
OUT_S="$(O="$TMP/O7-stale" CR_NOW="$NOW" bash "$HARNESS_BIN" status 2>&1)"; RC=$?
ck "NO record at all exits 2 and prints ABSENT (an absent record never reads as fine)" \
   "$([ "$RC" -eq 2 ] && q 'harness status — ABSENT' "$OUT_S" && echo 0 || echo 1)"
O="$TMP/O7b"; mkdir -p "$O/state"
cycle_record_write "$O" start=$(( NOW - 5000 )) end="$NOW" cycle=1 interval=240 selected="issue:none" \
  selected_n=0 dispatched=0 ids=- nothing="gate:merge-priority" placement=refuse placed_on=none \
  bound=disk lpc_self=372 >/dev/null
OUT_D="$(O="$O" CR_NOW="$NOW" bash "$HARNESS_BIN" status 2>&1)"; RC=$?
ck "a STALE newest record exits 1 and prints DEGRADED (not HEALTHY, not 'no data')" \
   "$([ "$RC" -eq 1 ] && q 'harness status — DEGRADED' "$OUT_D" && echo 0 || echo 1)"
ck "  …and shows WHY that cycle dispatched nothing (gate + bound) from the record alone" \
   "$(q 'nothing=gate:merge-priority' "$OUT_D" && q 'bound=disk' "$OUT_D" && echo 0 || echo 1)"
OUT_J="$(O="$TMP/O7" CR_NOW="$NOW" bash "$HARNESS_BIN" status --json 2>&1)"
# ⛔ PARSED, NEVER GREPPED. The assertion this replaces looked for the substring '"verdict": "HEALTHY"'
# and PASSED while `status --json` was emitting **invalid JSON**: `cycle_history` separates its fields
# with a RAW TAB (`age=<n>\t<record>`) and the state dir was interpolated unquoted, so `json.loads`
# refused the document ('Invalid control character at line 5 column 24') and only a substring reader
# could not tell. A substring match cannot fail on a malformed document, so it certified nothing.
ck "--json emits a PARSEABLE object — parsed with json.loads, not grepped (a substring match passed while the output was INVALID JSON)" \
   "$(printf '%s' "$OUT_J" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("verdict")=="HEALTHY" and len(d.get("cycles") or [])==1 else 1)' 2>/dev/null && echo 0 || echo 1)"
# The SECOND trigger, independently: a state dir whose path carries a double quote. Without escaping
# this closes the JSON string early and `json.loads` throws — so this case cannot pass by accident.
QDIR="$TMP/O7\"quote"; mkdir -p "$QDIR/state"
cycle_record_write "$QDIR" start=$(( NOW - 60 )) end="$NOW" cycle=1 interval=240 selected="issue:none" \
  selected_n=0 dispatched=0 ids=- nothing=no_candidate placement=place placed_on=cell-4 \
  bound=none lpc_self=7 >/dev/null 2>&1
OUT_QJ="$(O="$QDIR" CR_NOW="$NOW" bash "$HARNESS_BIN" status --json 2>&1)"
ck "  …and stays parseable when the STATE DIR contains a double quote (the escaper, not just the tab path)" \
   "$(printf '%s' "$OUT_QJ" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("stateDir")==sys.argv[1] else 1)' "$QDIR" 2>/dev/null && echo 0 || echo 1)"
ck "--last is honoured (asking for 1 shows one cycle, not the whole history)" \
   "$(_n="$(O="$TMP/O7" CR_NOW="$NOW" bash "$HARNESS_BIN" status --last 1 2>&1 | grep -c '^ *age=')"; [ "${_n:-0}" -eq 1 ] && echo 0 || echo 1)"

# ── §8 the transport: publish/read over a LOCAL bare origin (real pushes, real ls-remote) ────────
# ⛔ EACH SIMULATED BOX GETS ITS OWN `CAP_STATE_DIR`, BECAUSE THE SHIPPED LEDGER'S PREMISE IS ONE
# FILESYSTEM PER BOX (#2707). `cap_publish` proves authorship by what THIS box recorded at publish time,
# so two `pub` calls standing in for two boxes must not share that record — on the fleet they cannot
# (each cell has its own disk), and a test that let them share would be asserting the opposite of the
# property (it would "prove" one box may delete another's ref whenever their /tmp coincides).
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
PUB="$(CAP_NOW="$NOW" CAP_STATE_DIR="$TMP/state-cell-4" CAP_HOST="cell-4" cap_publish "$WORK" "$(rec cell-4 8 56 0 120000 14000 $NOW)")"; RC=$?
ck "a box PUBLISHES its record (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "  …under refs/boxes/<host>/<boxid>/<reading> (the reading rides the ref name: no fetch per box)" \
   "$(q 'ref=refs/boxes/cell-4/' "$PUB" && echo 0 || echo 1)"
CAP_NOW="$NOW" CAP_STATE_DIR="$TMP/state-cell-1" CAP_HOST="cell-1" cap_publish "$WORK" "$(rec cell-1 8 2982 5 90000 3000 $NOW)" >/dev/null 2>&1
READ="$(cap_read_fleet "$WORK")"; RC=$?
ck "a PEER reads the whole fleet with one ls-remote (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "  …and both boxes are in it, with their readings intact" \
   "$(q 'host=cell-4 .*lpc=7 ' "$READ" && q 'host=cell-1 .*lpc=372 ' "$READ" && echo 0 || echo 1)"
PL="$(printf '%s\n' "$READ" | cap_place cell-1)"
ck "placement over the REAL channel picks the idle box" \
   "$(q '^place=cell-4 ' "$PL" && echo 0 || echo 1)"
# A second reading from the SAME box must supersede the first, and must not delete a peer's.
CAP_NOW="$NOW" CAP_STATE_DIR="$TMP/state-cell-4" CAP_HOST="cell-4" cap_publish "$WORK" "$(rec cell-4 8 6100 3 120000 14000 $(( NOW + 60 )))" >/dev/null 2>&1
READ2="$(cap_read_fleet "$WORK")"
ck "a newer reading supersedes the old one for that box (one record per box, newest wins)" \
   "$(q 'host=cell-4 .*lpc=762 ' "$READ2" && echo 0 || echo 1)"
ck "  …and only ONE cell-4 ref survives (the publisher prunes its own old record)" \
   "$([ "$(printf '%s' "$READ2" | grep -c 'host=cell-4 ')" -eq 1 ] && echo 0 || echo 1)"
ck "  …and the peer's record is UNTOUCHED by that prune (authorship-scoped, never host- or fleet-wide)" \
   "$(q 'host=cell-1 ' "$READ2" && echo 0 || echo 1)"
PL2="$(printf '%s\n' "$READ2" | cap_place cell-1)"
ck "…and placement MOVES OFF the now-saturated box (cell-4 at lpc=762 is no longer idle)" \
   "$(q '^place=cell-1 ' "$PL2" && echo 0 || echo 1)"
ck "an UNREADABLE channel (a repo with no origin) is rc 2, so the caller must refuse to place" \
   "$(mkdir -p "$TMP/noorigin" && git init -q "$TMP/noorigin" && cap_read_fleet "$TMP/noorigin" >/dev/null 2>&1; [ "$?" -eq 2 ] && echo 0 || echo 1)"

# ── §9 WIRING: an unwired library is inert — the CONTROLLER must call it ─────────────────────────
echo
echo "── §9 the controller actually calls it (a defined-but-unused guard is inert) ──"
ck "orch-loop.sh sources capacity.sh from \$O, falling back to its own directory" \
   "$(grep -q 'capacity.sh' "$LOOP" && grep -q '_cap_mod' "$LOOP" && echo 0 || echo 1)"
ck "…and gates on the INTERFACE (declare -f), not on the file, so a stale copy cannot read as wired" \
   "$(grep -q 'declare -f cap_probe_local cap_place cap_read_fleet cap_publish' "$LOOP" && echo 0 || echo 1)"
# ⛔ AND THE GATE MUST NAME EVERY FUNCTION THE CYCLE CALLS (#3167, review round 10). The gate listed only
# the four pre-change names, so a stale `$O/capacity.sh` passed as WIRED and the cycle's
# `cap_publish_logged … || true` swallowed `command not found` — the box published NOTHING, silently. This
# arm derives the requirement from the two files: every `cap_*` that the module DEFINES and the
# controller CALLS must appear in the gate's own list.
GATELIST="$(sed -n 's/.*declare -f \(cap_[a-z_ ]*\) >\/dev\/null 2>&1; then CAPACITY=1.*/\1/p' "$LOOP" | head -1)"
MISSING=""
for _fn in $(grep -o 'cap_[a-z_]*' "$LOOP" | sort -u); do
  case " $GATELIST " in *" $_fn "*) : ;; *) grep -q "^$_fn() {" "$CAP" && MISSING="$MISSING $_fn" ;; esac
done
ck "…and the gate NAMES every module function the cycle calls — a stale capacity.sh cannot read as wired (missing:${MISSING:- none})" \
   "$([ -n "$GATELIST" ] && [ -z "$MISSING" ] && echo 0 || echo 1)"
ck "the cycle PROBES this box and PUBLISHES the reading (through the logged publish, #3167)" \
   "$(grep -q 'cap_probe_local "\$REPO"' "$LOOP" && grep -q 'cap_publish_logged "\$REPO"' "$LOOP" && echo 0 || echo 1)"
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
# ⛔ ANTI-THRASH: yielding to any slightly-idler peer would make the whole fleet stand down while it is
# healthy. The yield is bounded by a PREFER-ELSEWHERE line (CAP_YIELD_AT_LPC, 4.00 load/cpu), so a box
# that is not piling up TAKES the work. Both halves are asserted: the line exists AND it is compared.
ck "the yield is gated on this box being ABOVE the prefer-elsewhere line (CAP_YIELD_AT_LPC)" \
   "$(grep -q 'CAP_LPC_SELF:-0}" -ge "${CAP_YIELD_AT_LPC:-400}' "$LOOP" && echo 0 || echo 1)"
ck "  …so a lightly-loaded box keeps its work (no fleet-wide stand-down)" \
   "$(printf '%s\n' "$(rec cell-1 8 56 0 90000 3000 $NOW)" "$(rec cell-4 8 8 0 120000 14000 $NOW)" \
        | cap_place cell-1 | grep -q '^place=cell-4 ' && echo 0 || echo 1)"
ck "  …non-vacuity: the SAME fleet at lpc=450 on this box is exactly where it hands work over" \
   "$(CAP_YIELD_AT_LPC=400; [ 450 -ge "$CAP_YIELD_AT_LPC" ] && echo 0 || echo 1)"
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
# ⛔ INDENT-AGNOSTIC, AND THAT IS THE POINT (agent-infra#2293): the loop now has TWO record-write call
# sites (the ordinary cycle and the fork-starved path, different indents). A mutation that removes only
# the first leaves the other matching the wiring check, so it would prove nothing about the assertion.
sed 's/^\( *\)cycle_record_write "\$O" \\$/\1: cycle_record_write-disabled \\/' "$LOOP" > "$TMP/orch-no-record.sh"
grep -q 'cycle_record_write "\$O"' "$TMP/orch-no-record.sh" && r=1 || r=0
ck "mutation control: a loop with the record write REMOVED no longer satisfies the wiring check" "$r"
sed 's/^      if \[ "${CAP_STATE:-unavailable}" = "place" \]/      if false; then #/' "$LOOP" > "$TMP/orch-no-place.sh"
grep -q 'placed-on \${CAP_PLACE}' "$TMP/orch-no-place.sh" && r=0 || r=1
_pl="$(grep -n 'placed-on \${CAP_PLACE}' "$TMP/orch-no-place.sh" | head -1 | cut -d: -f1)"
if [ -n "${_pl:-}" ]; then
  sed -n "$(( _pl - 5 )),$(( _pl + 1 ))p" "$TMP/orch-no-place.sh" | grep -q 'if false; then' && r=0 || r=1
fi
ck "mutation control: a loop whose placement arm is disabled FAILS the arm assertion" "$r"

# ── §11 FORK HEADROOM: THE FIRST READ, AND THE ONE THAT STOPS A BOX ────────────────────────────
echo
echo "── §11 fork headroom is read BEFORE load, and a faked ceiling REFUSES by name (agent-infra#2293) ──"
# MEASURED 2026-10-21: cloud cell-4 (8 vCPU) could not spawn at all — `fork: Resource temporarily
# unavailable`, EAGAIN, rc 128 — at load 2.54/8 = 0.32x, 11 lanes, 16 `pi` procs. Placement read LOAD
# and would have placed a 12th lane there. Every arm below drives the SHIPPED `cap_place`/`cap_bound_hit`.

# THE FAKED CEILING: 15600 live procs against the box's own 15641 per-uid ceiling = 41 spare, which is
# under CAP_MIN_FORK_HEADROOM. Load and disk are HEALTHY on purpose — nothing but the fork read refuses.
EXH="$(recf cell-4 8 56 11 90000 3000 "$NOW" 15600 15641 1)"
# …and the SAME box with headroom: only the fork fields differ.
OKR="$(recf cell-4 8 56 11 90000 3000 "$NOW" 400 15641 1)"
PL_EXH="$(printf '%s\n' "$EXH" | cap_place cell-4)"; RC=$?
ck "a faked CEILING makes placement REFUSE (rc=1, not a silent place) [$PL_EXH]" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "  …and the refusal NAMES the read that refused: bound=fork_headroom" "$(q 'bound=fork_headroom' "$PL_EXH" && echo 0 || echo 1)"
ck "  …naming the box and the bound in detail= (a refusal an operator can act on)" \
   "$(q 'cell-4:fork_headroom' "$PL_EXH" && echo 0 || echo 1)"
PL_OK="$(printf '%s\n' "$OKR" | cap_place cell-4)"; RC=$?
ck "the SAME box with headroom places (the refusal is the fork read, not the test's fixtures) [$PL_OK]" \
   "$([ "$RC" -eq 0 ] && q '^place=cell-4 ' "$PL_OK" && echo 0 || echo 1)"
# ⛔ DISTINGUISHABLE FROM HIGH LOAD — the whole point of a NAMED bound. Same box, same fixtures, one
# number changed: load above the ceiling refuses `load_per_cpu`, and the two refusals cannot be confused.
PL_HOT="$(printf '%s\n' "$(recf cell-4 8 9000 11 90000 3000 "$NOW" 400 15641 1)" | cap_place cell-4)"
ck "a LOAD-saturated box refuses by its OWN name (bound=load_per_cpu), never fork_headroom" \
   "$(q 'bound=load_per_cpu' "$PL_HOT" && [ "$(printf '%s' "$PL_HOT" | grep -c fork_headroom)" -eq 0 ] && echo 0 || echo 1)"
PL_PRB="$(printf '%s\n' "$(recf cell-4 8 56 11 90000 3000 "$NOW" 400 15641 0)" | cap_place cell-4)"
ck "a box whose two-fork PROBE refused is refused as fork_probe (a different read, a different remedy)" \
   "$(q 'bound=fork_probe' "$PL_PRB" && echo 0 || echo 1)"
# ⛔ THE ORDER, ASSERTED ON THE SHIPPED FUNCTION: a record that is out of headroom AND over the load
# ceiling AND under the disk floor must report the FORK bound first (fork -> disk -> load).
PL_ALL="$(printf '%s\n' "$(recf cell-4 8 9000 11 100 3000 "$NOW" 15600 15641 1)" | cap_place cell-4)"
ck "ORDER: out of fork headroom AND over load AND under disk floor => fork_headroom is reported" \
   "$(q 'bound=fork_headroom' "$PL_ALL" && echo 0 || echo 1)"
PL_DL="$(printf '%s\n' "$(recf cell-4 8 9000 11 100 3000 "$NOW" 400 15641 1)" | cap_place cell-4)"
ck "ORDER: healthy fork + under disk floor + over load => DISK is reported (disk before load)" \
   "$(q 'bound=disk' "$PL_DL" && echo 0 || echo 1)"
# A record with no fork reading (a peer on a pre-#2293 tree) is `fork_unknown`, never eligible.
LEGACY="$(rec cell-4 8 56 11 90000 3000 "$NOW" | sed 's/ procs=.* boxid=/ boxid=/')"
ck "a LEGACY record (no fork fields) is refused as fork_unknown, not read as healthy" \
   "$(printf '%s\n' "$LEGACY" | cap_place cell-4 | grep -q 'bound=fork_unknown' && echo 0 || echo 1)"
ck "  …and cap_valid_record rejects it while cap_valid_base_record accepts it (a named cause, not a blanket one)" \
   "$( ( cap_valid_record "$LEGACY"; [ $? -eq 1 ] && cap_valid_base_record "$LEGACY" ) && echo 0 || echo 1)"
# ⛔ IDENTITY COMES BEFORE FORK, and this is the arm that pins the order (#2707): a record that names
# no box must be refused for THAT reason even though it also lacks a fork reading.
NOBOX="$(rec cell-4 8 56 11 90000 3000 "$NOW" | sed 's/ boxid=[^ ]*//')"
ck "a record naming NO box is refused as box_unknown — identity is the FIRST bound, before fork" \
   "$(printf '%s\n' "$NOBOX" | cap_place cell-4 | grep -q 'bound=box_unknown' && echo 0 || echo 1)"
# The arithmetic, on both adapters (ONE implementation): the record path and the in-process path agree.
_h_rec="$(cap_fork_headroom "$(recf x 8 56 0 90000 3000 "$NOW" 400 15641 1)")"
cap_h_for_vars 400 15641 _h; RC=$?
ck "headroom is procs_max - procs (both adapters agree: record=$_h_rec in-process=$_h)" \
   "$([ "$_h_rec" = "$_h" ] && [ "$_h" = "15241" ] && echo 0 || echo 1)"
ck "an UNBOUNDED ceiling (procs_max=0) is 'unbounded', never 'zero headroom'" \
   "$([ "$(cap_fork_headroom "$(recf x 8 56 0 90000 3000 "$NOW" 400 0 1)")" = "unbounded" ] && echo 0 || echo 1)"
ck "cap_procs_pair_vars returns a NUMERIC pair on this box (the read itself works)" \
   "$(cap_procs_pair_vars _pp _mm _ss && case "$_pp:$_mm" in *[!0-9:]*|:*) echo 1 ;; *) echo 0 ;; esac)"
# ⛔ AND THE **SHIPPED CALLER** IS DRIVEN TOO (verification gate, P0). `cap_procs_pair_vars` writes
# CALLER-NAMED variables using `printf -v`, and bash `local` is DYNAMIC — so a caller whose out-vars
# collide with the callee's working locals reads EMPTY strings. That happened twice in this very
# change (first the spawn gate's `p m src`, then this file's own `_cp_p _cp_m`), and both times every
# record published with an empty `procs=`/`procs_max=` while the suites stayed green because they only
# drove NON-colliding names. This arm drives the shipped caller, so a future rename on either side is
# caught here rather than in the fleet.
_pair="$(cap_procs_pair)"; RC=$?
_pnf="$(printf '%s' "$_pair" | awk '{print NF}' 2>/dev/null)"
ck "the SHIPPED caller cap_procs_pair returns THREE non-empty fields (dynamic scoping cannot empty it) [$_pair]" \
   "$([ "$RC" -eq 0 ] && [ "${_pnf:-0}" -eq 3 ] && [ -n "${_pair// /}" ] && echo 0 || echo 1)"
_p0="${_pair%% *}"; _p0="${_p0// /}"
ck "  …and its procs field is a real count, not the empty string that made every record invalid" \
   "$(case "$_p0" in ''|*[!0-9]*) echo 1 ;; *) [ "$_p0" -ge 1 ] && echo 0 || echo 1 ;; esac)"
# …and the RECORD the probe publishes must carry them (the caller chain, end to end).
_rp="$(cap_probe_local "$PWD" 0)"
ck "the published RECORD carries non-empty procs=/procs_max= (an empty field makes it fork_unknown to every peer)" \
   "$(case "$(cap_kv "$_rp" procs)" in ''|*[!0-9]*) echo 1 ;; *) case "$(cap_kv "$_rp" procs_max)" in ''|*[!0-9]*) echo 1 ;; *) echo 0 ;; esac ;; esac)"
# ⛔ THE TWO-FORK PROBE'S REFUSAL IS ITS OWN SIGNAL, measured rather than assumed: under a faked
# per-uid ceiling of 1 no fork can be made, and bash terminates the shell that tried (rc 254 — the
# contract `cap_cli probe` and the controller both key on). This is the ONE arm that needs no fixtures.
( ulimit -u 1 2>/dev/null; cap_fork_probe ) >/dev/null 2>&1; RC=$?
ck "a box that cannot fork returns 254 from the probe (the signal the controller reads as starved) [rc=$RC]" \
   "$([ "$RC" -eq 254 ] && echo 0 || echo 1)"

# ── §11b THE MUTATION CONTROL: delete the headroom read and the test above must FAIL ─────────────
# A gate whose test passes with the gate removed is not a test. The mutant is the SHIPPED file with ONE
# statement replaced (the bound is never read), and the SAME faked-exhausted record must then PLACE.
sed 's/^  forkb="\$(cap_fork_bound "\$r")"$/  forkb=""/' "$CAP" > "$TMP/cap-no-forkread.sh"
ck "mutation control: the mutant really lost the headroom read (no cap_fork_bound call in cap_bound_hit)" \
   "$([ "$(grep -c 'forkb="$(cap_fork_bound' "$TMP/cap-no-forkread.sh")" -eq 0 ] && echo 0 || echo 1)"
PL_MUT="$( ( . "$TMP/cap-no-forkread.sh"; printf '%s\n' "$EXH" | cap_place cell-4 ) 2>/dev/null )"; RC=$?
ck "mutation control: WITHOUT the read the fake-exhausted box is PLACED (the assertion discriminates) [rc=$RC $PL_MUT]" \
   "$([ "$RC" -eq 0 ] && q '^place=cell-4 ' "$PL_MUT" && echo 0 || echo 1)"

# ── §11c THE CONTROLLER SURVIVES IT: the gate runs BEFORE the first fork, and the state is NAMED ──
ck "orch-loop.sh defines fork_gate and calls it at the top of the cycle" \
   "$(grep -q '^fork_gate() {' "$LOOP" && grep -q '^  fork_gate$' "$LOOP" && echo 0 || echo 1)"
_g_line="$(grep -n '^  fork_gate$' "$LOOP" | head -1 | cut -d: -f1)"
_first_fork="$(grep -n 'CYCLE_T0="$(date +%s)"' "$LOOP" | head -1 | cut -d: -f1)"
ck "  …and the gate sits BEFORE the cycle's first fork (gate=$_g_line, date=$_first_fork)" \
   "$([ -n "${_g_line:-}" ] && [ -n "${_first_fork:-}" ] && [ "$_g_line" -lt "$_first_fork" ] && echo 0 || echo 1)"
ck "the STARVED cycle naps on the fork-free timer (a \`sleep\` would spawn and kill it)" \
   "$(grep -qF -- 'fork_free_sleep $(( 10#${CYC}' "$LOOP" && echo 0 || echo 1)"
ck "  …and the timer is a \`read -t\` on a pre-opened FIFO, not a child process" \
   "$(grep -q 'read -t "$secs" -r -u 9' "$LOOP" && echo 0 || echo 1)"
_n_line="$(grep -n 'nothing="$_cr_why"' "$LOOP" | head -1 | cut -d: -f1)"
_l_line="$(grep -n 'fork="$_cr_fork"' "$LOOP" | head -1 | cut -d: -f1)"
ck "  …and the starved cycle still WRITES A RECORD (a starved box with no record is silent)" \
   "$([ -n "${_n_line:-}" ] && [ -n "${_l_line:-}" ] && echo 0 || echo 1)"
ck "  …carrying the STATE, not a generic skip: fork_exhausted on a failed probe, fork_headroom when low" \
   "$(grep -q -- '_cr_why="fork_exhausted"' "$LOOP" && grep -q -- '_cr_why="fork_headroom"' "$LOOP" && echo 0 || echo 1)"
ck "  …and it writes the HEARTBEAT with a builtin, so no supervisor concludes the controller is gone" \
   "$(grep -qF -- "printf '%s\\n' \"\${_ft0}\" > \"\$O/heartbeat\"" "$LOOP" && echo 0 || echo 1)"
ck "the probe's rc=254 is read as fork_exhausted, not as 'no numbers from the probe'" \
   "$(grep -q 'CAP_RC:-0}" -eq 254' "$LOOP" && echo 0 || echo 1)"
# THE LOCAL GATE ORDER: the fork arm must be evaluated BEFORE the load arm.
# ⛔ ANCHORED INSIDE THE GATE BLOCK, AND REQUIRING A UNIQUE MATCH (#2927 verification). Each arm
# stopped being an `elif` line and became its own guard, so an `elif` pattern matched NOTHING and this
# order assertion went red on an empty reading — but the obvious repair, anchoring on ``^  if [
# "${FORK_STARVED:-0}" = "1" ]; then``, matched THREE lines (the FORK-STARVED cycle block, the gate arm
# and the sleep block) and `head -1` silently took the FIRST, an unrelated one. That is a false pass of
# exactly the class this suite exists to prevent: deleting the gate-chain fork arm altogether still
# read `fork=3263 < load=5601` and PASSED. So the anchors are resolved INSIDE the vector's own markers,
# and each must match EXACTLY ONE line there — a non-unique anchor reddens instead of taking a guess.
GUARD_BLOCK="$(sed -n '/# \[gatevec:begin\]/,/# \[gatevec:end\]/p' "$LOOP")"
_fk_pat='  if [ "${FORK_STARVED:-0}" = "1" ]; then'
_ld_pat='  if [ "$L" -ge "$MAX_LOAD" ]; then'
_fk_n="$(printf '%s\n' "$GUARD_BLOCK" | grep -cxF "$_fk_pat")"
_ld_n="$(printf '%s\n' "$GUARD_BLOCK" | grep -cxF "$_ld_pat")"
_fk_line="$(printf '%s\n' "$GUARD_BLOCK" | grep -nxF "$_fk_pat" | head -1 | cut -d: -f1)"
_ld_line="$(printf '%s\n' "$GUARD_BLOCK" | grep -nxF "$_ld_pat" | head -1 | cut -d: -f1)"
ck "the controller's OWN chain checks fork BEFORE load (offsets in the gate block: fork=$_fk_line load=$_ld_line)" \
   "$([ -n "${_fk_line:-}" ] && [ -n "${_ld_line:-}" ] && [ "${_fk_n:-0}" -eq 1 ] && [ "${_ld_n:-0}" -eq 1 ] \
       && [ "$_fk_line" -lt "$_ld_line" ] && echo 0 || echo 1)"
ck "  …and each anchor is UNIQUE in that block (fork×$_fk_n load×$_ld_n), so neither can resolve to a look-alike" \
   "$([ "${_fk_n:-0}" -eq 1 ] && [ "${_ld_n:-0}" -eq 1 ] && echo 0 || echo 1)"
ck "the cycle record carries the fork reading (fork= fork_procs= fork_max=)" \
   "$(grep -q 'fork="$_cr_fork" fork_procs=' "$LOOP" && echo 0 || echo 1)"
# THE VERDICT: a fresh record that says fork=starved is FORK-STARVED, rc 1 — driven, not grepped.
VO="$TMP/verdict-o"; mkdir -p "$VO/state"
printf 'start=%s end=%s cycle=7 interval=240 nothing=fork_exhausted placement=fork_exhausted bound=fork_probe fork=starved fork_procs=15600 fork_max=15641\n' \
  "$NOW" "$NOW" > "$VO/state/cycles"
VOUT="$( CR_NOW="$NOW" cycle_verdict "$VO" )"; RC=$?
ck "a FRESH record with fork=starved is the NAMED non-zero state FORK-STARVED (rc=$RC) [$VOUT]" \
   "$([ "$RC" -eq 1 ] && q '^FORK-STARVED ' "$VOUT" && echo 0 || echo 1)"
ck "  …and the verdict NAMES the reads (procs=/procs_max=), not just an adjective" \
   "$(q 'procs=15600 procs_max=15641' "$VOUT" && echo 0 || echo 1)"
printf 'start=%s end=%s cycle=7 interval=240 nothing=fork_exhausted fork=starved\n' \
  "$(( NOW - 100000 ))" "$(( NOW - 100000 ))" > "$VO/state/cycles"
VOUT2="$( CR_NOW="$NOW" cycle_verdict "$VO" )"; RC=$?
ck "  …but a STALE starved record is DEGRADED (a dead controller is not a live starved one)" \
   "$([ "$RC" -eq 1 ] && q '^DEGRADED ' "$VOUT2" && echo 0 || echo 1)"
printf 'start=%s end=%s cycle=7 interval=240 nothing=none fork=ok\n' "$NOW" "$NOW" > "$VO/state/cycles"
VOUT3="$( CR_NOW="$NOW" cycle_verdict "$VO" )"; RC=$?
ck "  …and a healthy record is still HEALTHY (the new arm did not swallow the ordinary case)" \
   "$([ "$RC" -eq 0 ] && q '^HEALTHY ' "$VOUT3" && echo 0 || echo 1)"
# ⛔ `fork=low` IS HELD TOO (review P2, driven). The writer records `fork=low` on the SAME path that
# records `placement=fork_held` and `dispatched=0`; grading that HEALTHY said "it is self-dispatching"
# about a cycle that dispatched NOTHING — the false PASS this verdict exists to close. There was no
# `fork=low` arm at all, so the gap could not be seen.
printf 'start=%s end=%s cycle=7 interval=240 nothing=fork_headroom placement=fork_held bound=fork_headroom fork=low fork_procs=15620 fork_max=15641\n' \
  "$NOW" "$NOW" > "$VO/state/cycles"
VOUTL="$( CR_NOW="$NOW" cycle_verdict "$VO" )"; RC=$?
ck "a FRESH record with fork=low (placed on the HELD path, dispatched=0) is FORK-STARVED, never HEALTHY (rc=$RC) [$VOUTL]" \
   "$([ "$RC" -eq 1 ] && q '^FORK-STARVED ' "$VOUTL" && q 'why=fork_headroom' "$VOUTL" && echo 0 || echo 1)"
ck "  …and it is DISTINGUISHED from the failed-probe case by its own why= (low headroom, not 'cannot fork')" \
   "$(! q 'why=fork_exhausted' "$VOUTL" && echo 0 || echo 1)"
# ⛔ AN UNSTAMPED RECORD IS NOT A STALE ONE (review P1, driven). The writer stamps 0 when it could not
# read a clock without a fork; aged against epoch 0 that record is "infinitely old", so `harness status`
# told the operator to START a controller that had just written the record — the wrong remedy on the
# bash-3.2 box the fork work exists for. UNREADABLE (rc 2) is "cannot answer", which is never a pass.
printf 'start=0 end=0 cycle=7 interval=240 nothing=fork_headroom placement=fork_held bound=fork_headroom fork=low\n' > "$VO/state/cycles"
VOUTU="$( CR_NOW="$NOW" cycle_verdict "$VO" )"; RC=$?
ck "an UNSTAMPED record (start=0) is UNREADABLE rc 2 — not DEGRADED, and never HEALTHY (rc=$RC) [$VOUTU]" \
   "$([ "$RC" -eq 2 ] && q '^UNREADABLE ' "$VOUTU" && q 'newest_record_unstamped' "$VOUTU" && echo 0 || echo 1)"
# ── THE STARVED WRITE REALLY SPENDS NO FORK (review P1, DRIVEN — the arm that reproduces the defect) ──
# Under `ulimit -u 1` no process can be created, so ANY `$( )` on the writer's path TERMINATES the
# shell (bash retries the fork four times, then exits 254) — and the record the starved box needs is
# never written. Measured on the pre-change writer: rc=254 and NO file. `cap_san`'s per-field
# substitution was the second offender, found by driving this arm, not by reading the diff.
SW="$TMP/starved-write"; mkdir -p "$SW/state"
SWOUT="$( ( ulimit -u 1 2>/dev/null
  . "$CR"
  cycle_record_write "$SW" start=1792598400 end=1792598400 cycle=9 nothing=fork_exhausted placement=fork_held bound=fork_probe fork=starved 2>/dev/null
  printf 'rc=%s' "$?" ) 2>/dev/null )"
ck "the STARVED write path survives a box that cannot fork at all — no \$( ) anywhere in it (got '${SWOUT:-<the shell died>}')" \
   "$([ "$SWOUT" = 'rc=0' ] && echo 0 || echo 1)"
ck "  …and the record is really ON DISK, carrying the fork reading the verdict needs" \
   "$(q 'fork=starved' "$(cat "$SW/state/cycles" 2>/dev/null)" && q 'placement=fork_held' "$(cat "$SW/state/cycles" 2>/dev/null)" && echo 0 || echo 1)"
ck "  …and the sanitiser still normalises a hostile value (quotes, spaces and backticks stripped by PARAMETER EXPANSION, not by tr)" \
   "$([ "$(. "$CR"; cr_san "a b\"c'd\`e")" = 'a_bcde' ] && echo 0 || echo 1)"
# THE SPAWN POINT: fork before disk before load, with its own refusal code.
SG="$HERE/spawn-gate.sh"
# ⛔ 73 — and the LABEL must carry the same number the assertion greps. It read "(74)" after the
# renumber, so the suite printed a green line naming the exact collision (#2293 x #2409: two gates
# on 74 with opposite remedies) that the renumber exists to remove. A green label that states the
# defect is worse than a red arm: operators and lanes read the label, not the grep.
ck "the spawn gate declares its OWN fork refusal code (73), distinct from land (74), disk (77) and load (75)" \
   "$(grep -q '^AGENT_FORK_REFUSED=73$' "$SG" && echo 0 || echo 1)"
_sf="$(grep -n 'spawn_fork_state _fstate _fdetail' "$SG" | head -1 | cut -d: -f1)"
_sd="$(grep -n 'dpath="${DISK_GATE_PATH:-$PWD}"' "$SG" | head -1 | cut -d: -f1)"
_sl="$(grep -n 'if ! can_spawn "$l"; then' "$SG" | head -1 | cut -d: -f1)"
ck "  …and run_agent evaluates FORK before DISK before LOAD (f=$_sf d=$_sd l=$_sl)" \
   "$([ -n "${_sf:-}" ] && [ -n "${_sd:-}" ] && [ -n "${_sl:-}" ] && [ "$_sf" -lt "$_sd" ] && [ "$_sd" -lt "$_sl" ] && echo 0 || echo 1)"

# ── THE CALLER'S OWN CGROUP, NOT ONLY THE MOUNT ROOT (review P2, DRIVEN) ────────────────────────
# Reading only /sys/fs/cgroup/pids.max left the arm DEAD wherever processes live in a slice: measured
# on a fleet cell the root has no pids.max at all, while /proc/self/cgroup names
# /system.slice/<svc>.service and THAT directory's pids.max is 4692 — so the binding ceiling was never
# seen and the arm always answered src=uid. Fixture trees drive both hierarchies and the ancestor walk.
CGF="$TMP/cgfix"; mkdir -p "$CGF/cg/system.slice/anvil.service" "$CGF/cg/pids/docker/abc"
printf '9999\n' > "$CGF/cg/pids.max";          printf '1\n'  > "$CGF/cg/pids.current"
printf '50\n'   > "$CGF/cg/system.slice/anvil.service/pids.max"
printf '40\n'   > "$CGF/cg/system.slice/anvil.service/pids.current"
printf '0::/system.slice/anvil.service\n' > "$CGF/self2"
printf '4:pids:/docker/abc\n1:name=systemd:/docker/abc\n' > "$CGF/self1"
printf '20\n' > "$CGF/cg/pids/docker/abc/pids.max"; printf '5\n' > "$CGF/cg/pids/docker/abc/pids.current"
CG_M=""; CG_C=""
CAP_CGROUP_MOUNT="$CGF/cg" CAP_SELF_CGROUP_FILE="$CGF/self2" cap_cgroup_pair_vars CG_M CG_C; RC=$?
ck "the caller's OWN cgroup dir is read (cgroup v2 fixture: ${CG_M:-?}/${CG_C:-?} = 50/40, NOT the root's 9999/1)" \
   "$([ "$RC" -eq 0 ] && [ "$CG_M" = 50 ] && [ "$CG_C" = 40 ] && echo 0 || echo 1)"
# An ANCESTOR slice: the ceiling is as often set on the slice above the service as on its own dir.
rm -f "$CGF/cg/system.slice/anvil.service/pids.max" "$CGF/cg/system.slice/anvil.service/pids.current"
printf '77\n' > "$CGF/cg/system.slice/pids.max"; printf '3\n' > "$CGF/cg/system.slice/pids.current"
CG_M=""; CG_C=""
CAP_CGROUP_MOUNT="$CGF/cg" CAP_SELF_CGROUP_FILE="$CGF/self2" cap_cgroup_pair_vars CG_M CG_C; RC=$?
ck "  …and an ANCESTOR slice is walked to when the service dir carries no ceiling (${CG_M:-?}/${CG_C:-?} = 77/3)" \
   "$([ "$RC" -eq 0 ] && [ "$CG_M" = 77 ] && [ "$CG_C" = 3 ] && echo 0 || echo 1)"
CG_M=""; CG_C=""
CAP_CGROUP_MOUNT="$CGF/cg" CAP_SELF_CGROUP_FILE="$CGF/self1" cap_cgroup_pair_vars CG_M CG_C; RC=$?
ck "  …and cgroup v1 is handled (pids hierarchy under its own mount point: ${CG_M:-?}/${CG_C:-?} = 20/5)" \
   "$([ "$RC" -eq 0 ] && [ "$CG_M" = 20 ] && [ "$CG_C" = 5 ] && echo 0 || echo 1)"
CAP_CGROUP_MOUNT="$CGF/cg" CAP_SELF_CGROUP_FILE="$CGF/absent" cap_cgroup_pair_vars CG_M CG_C; RC=$?
ck "  …and an unreadable /proc/self/cgroup returns rc 1, so the root-only fallback arms still answer" \
   "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
# Fork-free: the resolver runs on a box that cannot fork, because a `$( )` here would be the fork that
# kills the reader it exists for.
CG_M=""; CG_C=""
CGRC="$( ( ulimit -u 1 2>/dev/null
  CAP_CGROUP_MOUNT="$CGF/cg" CAP_SELF_CGROUP_FILE="$CGF/self1" cap_cgroup_pair_vars CG_M CG_C
  printf 'rc=%s pair=%s/%s' "$?" "$CG_M" "$CG_C" ) 2>/dev/null )"
ck "  …and the resolver spawns NOTHING: it answers under \`ulimit -u 1\` ($CGRC)" \
   "$([ "$CGRC" = 'rc=0 pair=20/5' ] && echo 0 || echo 1)"

# ── §10 self-registration ───────────────────────────────────────────────────────────────────────
echo
echo "── §10 this suite is EXECUTED by CI, not merely named ──"
# ⛔ MEMBERSHIP IS READ FROM WHAT THE RUNNER EXECUTES, NOT FROM ITS TEXT (agent-infra#2609). The list
# is DERIVED from the tree now, so the driver's text names no suite at all — a `grep` of the driver
# file would read 1 for `git show HEAD:…` and 0 here, i.e. it asserted the OLD enumeration and went
# red the moment the list became a derivation. `--list` is the runner's own oracle (the same one the
# CI lane reads), exactly as spawn-gate.test.sh asserts its own membership.
SHARDS="$ROOT/scripts/run-bash-shards.sh"
ck "capacity-placement.test.sh is EXECUTED by run-bash-shards.sh --list (the ONE list both lanes run)" \
   "$(bash "$SHARDS" --list 2>/dev/null | grep -qx 'scripts/orchestrator-harness/capacity-placement.test.sh' && echo 0 || echo 1)"

# ── §12 THE FLEET VIEW (#2707): three boxes named `cmux`, one origin, NO CAP_HOST ───────────────
echo
echo "── §12 the fleet view does not collapse: one hostname, distinct identities, every record survives ──"
# MEASURED 2026-10-28 on the three cloud cells, read from each box:
#   hostname /etc/machine-id dbus-machine-id /proc/…/boot_id btime cgroup-slice  => ALL IDENTICAL
#   global IPv4 10.238.144.{4,3,2}                                              => UNIQUE
# So the identity the fleet keys on CANNOT be the hostname (the old defect) and cannot be machine-id
# or a per-boot uuid (both cloned with the image — which is why machine-id is not even a fallback:
# see capacity.sh's header). The suite therefore stubs the DERIVATION and nothing else — no
# `CAP_HOST=cell-N`, no `CAP_BOXID`: that is exactly the hole the issue found in §8, whose fixtures
# supplied the uniqueness production lacks.
O2="$TMP/origin2707.git"; W2="$TMP/work2707"; HB="$TMP/bin2707"
git init -q --bare "$O2" >/dev/null 2>&1
git init -q "$W2" >/dev/null 2>&1
( cd "$W2" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O2" && git push -q origin HEAD:main ) >/dev/null 2>&1
mkdir -p "$HB"; printf '#!/bin/sh\necho cmux\n' > "$HB/hostname"; chmod +x "$HB/hostname"
# pub <netid> <ncpu> <at> <boot> <load1> — ONE box publishes through the SHIPPED probe + publish.
# Both boxes report `hostname` = `cmux` (the same /etc/hostname, measured) and differ only in the
# identity a derivation can actually find.
# ⛔ EACH BOX GETS ITS OWN `CAP_STATE_DIR`. The authorship ledger is per-BOX state (capacity.sh proves a
# prune by what THIS box recorded), and on the fleet each cell has its own filesystem. Two simulated
# boxes sharing one ledger would be a DIFFERENT scenario — one state store, two writers — and §13 drives
# that one explicitly rather than letting it leak into every arm here.
pub() {
  # ⛔ THE ARGS GO INTO NAMED VARIABLES FIRST: a bash function's `$1` is ITS OWN, so an override that
  # reads `$1` inside `cap_probe_local` would read the CALLEE's (empty) positional params and silently
  # publish `ncpu=` — a record every peer refuses.
  _p_id="$1"; _p_ncpu="$2"; _p_at="$3"; _p_boot="$4"; _p_load="$5"
  # ⛔ NO IDENTITY SEAM AT ALL: §1 exported `CAP_HOST=cell-1`, and inheriting it here would hide the
  # very defect #2707 measures. Both seams are cleared, so the ONLY identity is the derived one.
  ( PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/state-$_p_id"
    cap_hw_uuid()   { return 1; }
    cap_boxid_net() { printf '%s' "$_p_id"; }
    cap_ncpu()      { printf '%s' "$_p_ncpu"; }
    cap_boot_epoch(){ printf '%s' "$_p_boot"; }
    cap_load1_100() { printf '%s' "$_p_load"; }
    CAP_NOW="$_p_at" cap_probe_local "$W2" 0 2>/dev/null > "$TMP/rec2707"
    CAP_NOW="$_p_at" cap_publish "$W2" "$(cat "$TMP/rec2707")" )
}
A_BOOT=$(( NOW - 600 )); B_BOOT=$(( NOW - 300 ))
POUT1="$(pub 10.238.144.2 4 "$NOW" "$A_BOOT" 56)"; RC=$?
ck "box A (4-core, hostname cmux) publishes under its OWN derived identity — no CAP_HOST, no CAP_BOXID (rc=$RC)" \
   "$([ "$RC" -eq 0 ] && qF 'ref=refs/boxes/cmux/10.238.144.2/' "$POUT1" && echo 0 || echo 1)"
ck "  …the DEFAULT-path probe names the box and its boot epoch (an empty boxid is refused at publish)" \
   "$([ -n "$(cap_kv "$(cat "$TMP/rec2707")" boxid)" ] && [ "$(cap_kv "$(cat "$TMP/rec2707")" boot)" = "$A_BOOT" ] && echo 0 || echo 1)"
ck "  …and the publish RECORDED what it wrote, so a later prune can be proven rather than guessed" \
   "$(qF 'ledger=ok' "$POUT1" && echo 0 || echo 1)"
POUT2="$(pub 10.238.144.3 8 "$(( NOW + 60 ))" "$B_BOOT" 6100)"; RC=$?
ck "box B (8-core, the SAME hostname) publishes 60 s later (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
_refs="$(git -C "$W2" ls-remote --refs origin 'refs/boxes/*' | awk '{print $2}')"
ck "  …and BOTH refs survive: a publish prunes its OWN key, never a peer's (got $(printf '%s\n' "$_refs" | grep -c .) refs)" \
   "$([ "$(printf '%s\n' "$_refs" | grep -c .)" -eq 2 ] && echo 0 || echo 1)"
FLEET2="$(cap_read_fleet "$W2")"; RC=$?
ck "a peer READS TWO boxes, not one (rc=$RC) — the collapse is gone" \
   "$([ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$FLEET2" | grep -c '^host=cmux ')" -eq 2 ] && echo 0 || echo 1)"
ck "  …each carrying the identity that distinguishes it" \
   "$(q 'host=cmux .*boxid=10\.238\.144\.2' "$FLEET2" && q 'host=cmux .*boxid=10\.238\.144\.3' "$FLEET2" && echo 0 || echo 1)"
PL2="$(printf '%s\n' "$FLEET2" | cap_place cmux)"; RC=$?
ck "PLACEMENT COMPARES AGAINST A FLEET OF TWO and picks the idle 4-core box (not 'place here') [$PL2]" \
   "$([ "$RC" -eq 0 ] && q '^place=cmux ' "$PL2" && q 'evaluated=2 eligible=2' "$PL2" && q 'boxid=10.238.144.2' "$PL2" && echo 0 || echo 1)"
POUT3="$(pub 10.238.144.3 8 "$(( NOW + 180 ))" "$B_BOOT" 7600)"
ck "B's next reading supersedes B's own old one and leaves A's key alone (2 refs, one per box)" \
   "$([ "$(git -C "$W2" ls-remote --refs origin 'refs/boxes/cmux/*' | grep -c .)" -eq 2 ] && echo 0 || echo 1)"
ck "  …B holds exactly ONE ref (a box DOES prune its own superseded readings — via its ledger)" \
   "$([ "$(git -C "$W2" ls-remote --refs origin 'refs/boxes/cmux/10.238.144.3/*' | grep -c .)" -eq 1 ] && echo 0 || echo 1)"
ck "  …and a publish under a key nothing else holds reports foreign=0 (a reading, not silence)" \
   "$(qF 'foreign=0' "$POUT3" && echo 0 || echo 1)"
# A legacy two-segment ref (pre-#2707) under the shared hostname: visible, named, NEVER chosen.
git -C "$W2" push -q origin "$(git -C "$W2" rev-parse HEAD):refs/boxes/cmux/$NOW-8-56-0-120000-14000-400-15641-1" 2>/dev/null
FLEET3="$(cap_read_fleet "$W2")"
ck "a LEGACY ref (no boxid) is read as an unattributable box, not silently dropped" \
   "$([ "$(printf '%s\n' "$FLEET3" | grep -c '^host=cmux ')" -eq 3 ] && echo 0 || echo 1)"
PL3="$(printf '%s\n' "$FLEET3" | cap_place cmux)"
ck "  …and placement REFUSES to choose it, naming the bound: ineligible=[cmux:box_unknown]" \
   "$(qF 'cmux:box_unknown' "$PL3" && echo 0 || echo 1)"
# ── fail-closed identity: no name, no record ─────────────────────────────────────────────────────
# (a function whose BODY is a subshell: bash 3.2 cannot carry nested double quotes inside "$( … )")
noidpub() (
  PATH="$HB:$PATH" CAP_STATE_DIR="$TMP/state-none"
  cap_hw_uuid() { return 1; }
  cap_boxid_net() { return 1; }
  cap_publish "$W2" \
    "host=cmux ncpu=8 load1=56 lpc=7 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=$NOW procs=400 procs_max=15641 fork=1 boot=$NOW"
)
POUT6="$(noidpub 2>&1)"; RC=$?
ck "a box with NO derivable identity REFUSES to publish (why=no-box-identity) — machine-id is NOT a fallback (rc=$RC)" \
   "$([ "$RC" -eq 1 ] && qF 'why=no-box-identity' "$POUT6" && echo 0 || echo 1)"
ck "  …so a cloned image cannot manufacture a false attribution under a key another box holds" \
   "$([ "$(git -C "$W2" ls-remote --refs origin 'refs/boxes/cmux/*' | grep -c .)" -eq 3 ] && echo 0 || echo 1)"
# ── the token is a path segment: it cannot be made to name a PEER's key ──────────────────────────
_TOK="$( ( . "$CAP"; cap_ref_token 'x/../../10.0.0.9' ) )"
ck "the identity token cannot carry a slash (a 'x/../../peer' identity must not become a peer's ref)" \
   "$([ "$_TOK" = "x....10.0.0.9" ] && echo 0 || echo 1)"
( . "$CAP"; cap_boxid_ok "$(cap_ref_token '..')" ) >/dev/null 2>&1; RC=$?
ck "  …and a token of dots is not a valid identity (git refuses it too; it is the one walking shape) (rc=$RC)" \
   "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
for _bad in 'a..b' 'x.lock' 'a b'; do
  ( . "$CAP"; cap_boxid_ok "$_bad" ) >/dev/null 2>&1; RC=$?
  ck "  …and '$_bad' is refused before git sees it (git check-ref-format would reject it: a named reason, not push-refused) (rc=$RC)" \
     "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
done
( . "$CAP"; cap_ref_for "host=.. ncpu=8 load1=56 lpc=7 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=$NOW procs=400 procs_max=15641 fork=1 boxid=10.0.0.1 boot=$NOW" ) >/dev/null 2>&1; RC=$?
ck "  …and a record whose HOST is '..' cannot produce a ref at all (the host is a path segment too) (rc=$RC)" \
   "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
# ── CAP_HOST survives as the EXPLICIT override (the issue requires it stay) ──────────────────────
hostov() ( PATH="$HB:$PATH"; CAP_HOST="pi-cell-4" cap_probe_local "$W2" 0 )
_HOV="$(hostov 2>/dev/null)"
ck "CAP_HOST is still the explicit override (a deploy may name the box pi-cell-4)" \
   "$(q '^host=pi-cell-4 ' "$_HOV" && echo 0 || echo 1)"

# ── §13 THE PRUNE'S PROOF (review round 2): authorship is a FACT, never an inference ─────────────
echo
echo "── §13 the prune proves authorship: a mis-keyed PEER is never deleted, and the ledger is the proof ──"
# ⛔ THE FIRST DRAFT OF THIS FIX WAS WRONG HERE, AND THIS IS THE ARM THAT PINS IT. It deleted a ref when
# it shared our key AND our `boot` epoch ("this machine wrote it since it booted"). Both facts are shared
# on a mis-keyed fleet — measured, two cells share a btime — so the second publisher deleted the first
# box's LIVE ref and reported `foreign=0`: the #2707 collapse, restored, silently. Reproduced before the
# fix, on this suite's shape: A (ncpu 4) published, B (ncpu 8, same key, same boot) published 60 s later,
# refs=1, reader saw one box, `place=cmux`. The two boxes below differ ONLY in their ledger — which is
# exactly the fact a peer cannot forge.
O4="$TMP/origin-c1.git"; W4="$TMP/work-c1"
git init -q --bare "$O4" >/dev/null 2>&1; git init -q "$W4" >/dev/null 2>&1
( cd "$W4" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O4" && git push -q origin HEAD:main ) >/dev/null 2>&1
pubc() { _c_state="$1"; _c_id="$2"; _c_ncpu="$3"; _c_at="$4"; _c_boot="$5"; _c_load="$6"
  ( PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$_c_state"
    cap_hw_uuid() { return 1; }; cap_boxid_net() { printf '%s' "$_c_id"; }
    cap_ncpu() { printf '%s' "$_c_ncpu"; }; cap_boot_epoch() { printf '%s' "$_c_boot"; }
    cap_load1_100() { printf '%s' "$_c_load"; }
    CAP_NOW="$_c_at" cap_probe_local "$W4" 0 2>/dev/null > "$TMP/recc"
    CAP_NOW="$_c_at" cap_publish "$W4" "$(cat "$TMP/recc")" ) }
SHARED_BOOT=$(( NOW - 600 ))
P1="$(pubc "$TMP/state-c1a" 10.238.144.2 4 "$NOW" "$SHARED_BOOT" 56)"; RC=$?
ck "§13 box A (4-core) publishes under the shared key (rc=$RC)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
P2="$(pubc "$TMP/state-c1b" 10.238.144.2 8 "$(( NOW + 60 ))" "$SHARED_BOOT" 6100)"; RC=$?
ck "§13 box B publishes under the SAME key AND the SAME boot epoch — the case the first draft deleted (rc=$RC)" \
   "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "  …and A's LIVE ref SURVIVES: a shared (key, boot) is NOT authorship proof (got $(git -C "$W4" ls-remote --refs origin 'refs/boxes/*' | grep -c .) refs)" \
   "$([ "$(git -C "$W4" ls-remote --refs origin 'refs/boxes/*' | grep -c .)" -eq 2 ] && echo 0 || echo 1)"
ck "  …and the publish SAYS another writer is under its key (foreign=1), instead of a clean foreign=0 [$P2]" \
   "$(qF 'foreign=1' "$P2" && echo 0 || echo 1)"
FLEETC="$(cap_read_fleet "$W4")"
ck "  …the reader marks that key collide=1, so the ambiguity is visible, not 'newest wins'" \
   "$(q 'boxid=10\.238\.144\.2 .*collide=1' "$FLEETC" && echo 0 || echo 1)"
PLC="$(printf '%s\n' "$FLEETC" | cap_place cmux)"; RC=$?
ck "  …and cap_place REFUSES the whole decision rather than placing on a box it cannot name (rc=$RC) [$PLC]" \
   "$([ "$RC" -eq 1 ] && q '^refuse bound=identity_collision' "$PLC" && q 'detail=cmux/10.238.144.2' "$PLC" && echo 0 || echo 1)"
# ── the ledger still prunes: a box is allowed to delete what IT wrote ─────────────────────────────
P3="$(pubc "$TMP/state-c1a" 10.238.144.2 4 "$(( NOW + 120 ))" "$SHARED_BOOT" 56)"
ck "§13 a box still supersedes its OWN previous reading — deleting what its ledger proves it wrote" \
   "$([ "$(git -C "$W4" ls-remote --refs origin 'refs/boxes/cmux/10.238.144.2/*' | grep -c .)" -eq 2 ] &&
      qF "ref=refs/boxes/cmux/10.238.144.2/$(( NOW + 120 ))-" "$P3" && echo 0 || echo 1)"
# ⛔ THE INDISTINGUISHABLE RESIDUAL, asserted rather than hidden: two boxes sharing key AND ncpu AND
# boot carry no fourth fact that differs, so the channel cannot tell them apart. What MUST hold is that
# neither DESTROYS the other (the defect), even though the reader keeps the newest of that key.
O5="$TMP/origin-c2.git"; W5="$TMP/work-c2"
git init -q --bare "$O5" >/dev/null 2>&1; git init -q "$W5" >/dev/null 2>&1
( cd "$W5" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O5" && git push -q origin HEAD:main ) >/dev/null 2>&1
pubc5() { _c_state="$1"; _c_at="$2"
  ( PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$_c_state"
    cap_hw_uuid() { return 1; }; cap_boxid_net() { printf '10.238.144.7'; }
    cap_ncpu() { printf '8'; }; cap_boot_epoch() { printf '%s' "$SHARED_BOOT"; }
    cap_load1_100() { printf '56'; }
    CAP_NOW="$_c_at" cap_probe_local "$W5" 0 2>/dev/null > "$TMP/recc5"
    CAP_NOW="$_c_at" cap_publish "$W5" "$(cat "$TMP/recc5")" ) }
pubc5 "$TMP/state-c2a" "$NOW" >/dev/null 2>&1
pubc5 "$TMP/state-c2b" "$(( NOW + 60 ))" >/dev/null 2>&1
ck "§13 two boxes sharing key AND ncpu AND boot: NEITHER record is destroyed (no silent collapse at the writer)" \
   "$([ "$(git -C "$W5" ls-remote --refs origin 'refs/boxes/*' | grep -c .)" -eq 2 ] && echo 0 || echo 1)"
ck "  …the reader keeps the newest of that key (the stated residual: no fourth fact distinguishes them)" \
   "$([ "$(cap_read_fleet "$W5" | grep -c '^host=cmux ')" -eq 1 ] && echo 0 || echo 1)"
# ── boot=0 is UNKNOWN, not a different machine (no false fleet-wide refusal) ─────────────────────
O6="$TMP/origin-c3.git"; W6="$TMP/work-c3"
git init -q --bare "$O6" >/dev/null 2>&1; git init -q "$W6" >/dev/null 2>&1
( cd "$W6" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O6" && git push -q origin HEAD:main ) >/dev/null 2>&1
git -C "$W6" push -q origin "$(git -C "$W6" rev-parse HEAD):refs/boxes/cmux/10.238.144.8/$NOW-8-56-0-120000-14000-400-15641-1-0" 2>/dev/null
git -C "$W6" push -q origin "$(git -C "$W6" rev-parse HEAD):refs/boxes/cmux/10.238.144.8/$(( NOW + 60 ))-8-56-0-120000-14000-400-15641-1-$SHARED_BOOT" 2>/dev/null
ck "§13 a boot=0 reading beside a real one is ONE box with an unknown boot, NOT a collision" \
   "$([ "$(cap_read_fleet "$W6" | grep -c 'collide=1')" -eq 0 ] && echo 0 || echo 1)"
PL6="$(cap_read_fleet "$W6" | cap_place cmux)"; RC=$?
ck "  …so a transient boot-read failure does not refuse the whole fleet's placement (rc=$RC) [$PL6]" \
   "$([ "$RC" -eq 0 ] && q '^place=cmux ' "$PL6" && echo 0 || echo 1)"
# ⛔ …BUT AN UNREADABLE `boot` MUST NOT DISABLE THE DETECTOR (review round 3, B1). `ncpu` is always
# comparable: a box cannot change core count inside one boot, and an unreadable clock says nothing about
# how many cores it has. Dropping the whole record when `boot` was 0 let a 4-core and an 8-core box under
# ONE key read as one box, and `cap_place` placed — measured before the fix (0 collide marks, rc 0).
O7b="$TMP/origin-c4.git"; W7b="$TMP/work-c4"
git init -q --bare "$O7b" >/dev/null 2>&1; git init -q "$W7b" >/dev/null 2>&1
( cd "$W7b" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O7b" && git push -q origin HEAD:main ) >/dev/null 2>&1
git -C "$W7b" push -q origin "$(git -C "$W7b" rev-parse HEAD):refs/boxes/cmux/10.238.144.9/$NOW-4-5600-0-120000-14000-400-15641-1-0" 2>/dev/null
git -C "$W7b" push -q origin "$(git -C "$W7b" rev-parse HEAD):refs/boxes/cmux/10.238.144.9/$(( NOW + 60 ))-8-6100-0-120000-14000-400-15641-1-0" 2>/dev/null
ck "§13 two boxes under ONE key with boot UNREADABLE on both are still detected from ncpu (collide=1)" \
   "$([ "$(cap_read_fleet "$W7b" | grep -c 'collide=1')" -eq 1 ] && echo 0 || echo 1)"
PL7="$(cap_read_fleet "$W7b" | cap_place cmux)"; RC=$?
ck "  …so an unreadable clock cannot turn a real key collision into 'place here' (rc=$RC) [$PL7]" \
   "$([ "$RC" -eq 1 ] && q '^refuse bound=identity_collision' "$PL7" && echo 0 || echo 1)"
# ── a ledger that cannot be written is a LEAK, never a delete ────────────────────────────────────
noledger() ( CAP_STATE_DIR=/dev/null/nope
  PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID=""
  cap_hw_uuid() { return 1; }; cap_boxid_net() { printf '10.238.144.9'; }
  cap_ncpu() { printf '8'; }; cap_boot_epoch() { printf '%s' "$B_BOOT"; }
  cap_load1_100() { printf '56'; }
  CAP_NOW="$NOW" cap_probe_local "$W2" 0 2>/dev/null > "$TMP/recnl"
  CAP_NOW="$NOW" cap_publish "$W2" "$(cat "$TMP/recnl")" )
POUTNL="$(noledger 2>&1)"; RC=$?
ck "§13 an unwritable ledger still PUBLISHES and says so (ledger=unavailable), it never fails a dispatch (rc=$RC)" \
   "$([ "$RC" -eq 0 ] && qF 'ledger=unavailable' "$POUTNL" && echo 0 || echo 1)"
ck "  …and it deletes NOTHING it cannot prove: the three peer refs are all still there" \
   "$([ "$(git -C "$W2" ls-remote --refs origin 'refs/boxes/cmux/*' | grep -c .)" -eq 4 ] && echo 0 || echo 1)"
# ── the predicate itself, driven directly (the loop is not the only thing that must be right) ────
_probe_del() { ( . "$CAP"; cap_ref_deletable "$1" "$2" "$3" "$4" ) >/dev/null 2>&1; echo $?; }
_LED="$TMP/probe.ledger"; printf '%s\n' "refs/boxes/cmux/10.0.0.1/1-8-56-0-1-1-1-1-1-1" > "$_LED"
_REC="$(recf cmux 8 56 0 120000 14000 "$NOW" 400 15641 1)"
ck "§13 cap_ref_deletable: a ref this box's LEDGER names is deletable (rc=$(_probe_del "$_REC" refs/boxes/cmux/10.0.0.1/1-8-56-0-1-1-1-1-1-1 "$_LED" "$NOW"))" \
   "$([ "$(_probe_del "$_REC" refs/boxes/cmux/10.0.0.1/1-8-56-0-1-1-1-1-1-1 "$_LED" "$NOW")" -eq 0 ] && echo 0 || echo 1)"
ck "  …a FRESH ref under our own key that the ledger does NOT name is NOT deletable (the round-2 defect)" \
   "$([ "$(_probe_del "$_REC" refs/boxes/cmux/10.0.0.1/999-8-56-0-1-1-1-1-1-1 "$_LED" "$NOW")" -ne 0 ] && echo 0 || echo 1)"
ck "  …a STALE ref is deletable whatever the ledger says (the only cleanup an unattributable ref can get)" \
   "$([ "$(_probe_del "$(recf cmux 8 56 0 120000 14000 "$(( NOW - 5000 ))" 400 15641 1)" refs/boxes/cmux/old "$_LED" "$NOW")" -eq 0 ] && echo 0 || echo 1)"
ck "  …and NO ledger at all (a wiped /tmp) proves nothing, so a fresh ref is kept" \
   "$([ "$(_probe_del "$_REC" refs/boxes/cmux/10.0.0.1/999-8-56-0-1-1-1-1-1-1 "$TMP/missing.ledger" "$NOW")" -ne 0 ] && echo 0 || echo 1)"

# ── §12m MUTATION CONTROLS: each new assertion must go RED when its mechanism is removed ─────────
echo
echo "── §12m mutation controls: remove the mechanism, watch the arm above go red ──"
# (m1) restore the PRE-CHANGE prune (delete every fresh ref under our hostname) => box B eats box A.
sed 's/^cap_ref_deletable() {$/cap_ref_deletable() { return 0  # MUTANT: pre-#2707 host-scoped prune/' \
  "$CAP" > "$TMP/cap-hostprune.sh"
grep -q 'MUTANT' "$TMP/cap-hostprune.sh" && r=0 || r=1
ck "m1: the mutant really lost the authorship test (every fresh ref under the hostname is deletable)" "$r"
O3="$TMP/origin-m1.git"; W3="$TMP/work-m1"
git init -q --bare "$O3" >/dev/null 2>&1; git init -q "$W3" >/dev/null 2>&1
( cd "$W3" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O3" && git push -q origin HEAD:main ) >/dev/null 2>&1
m1pub() { _m_mod="$1"; _m_id="$2"; _m_ncpu="$3"; _m_boot="$4"; _m_load="$5"; _m_at="$6"
  ( . "$_m_mod"; PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/m1state-$_m_id"
    cap_hw_uuid() { return 1; }; cap_boxid_net() { printf '%s' "$_m_id"; }
    cap_ncpu() { printf '%s' "$_m_ncpu"; }; cap_boot_epoch() { printf '%s' "$_m_boot"; }
    cap_load1_100() { printf '%s' "$_m_load"; }
    CAP_NOW="$_m_at" cap_probe_local "$W3" 0 2>/dev/null > "$TMP/m1rec"
    CAP_NOW="$_m_at" cap_publish "$W3" "$(cat "$TMP/m1rec")" ) >/dev/null 2>&1; }
m1pub "$CAP" 10.238.144.2 4 "$A_BOOT" 56 "$NOW"
m1pub "$TMP/cap-hostprune.sh" 10.238.144.3 8 "$B_BOOT" 6100 "$(( NOW + 60 ))"
ck "m1: with the OLD host-scoped prune, two boxes collapse back to ONE ref (so the arm above discriminates)" \
   "$([ "$(git -C "$W3" ls-remote --refs origin 'refs/boxes/*' | grep -c .)" -eq 1 ] && echo 0 || echo 1)"
# (m2) restore the PRE-CHANGE reader grouping (one record per HOSTNAME) => two boxes read as one.
sed 's|^      key = h "/" bid$|      key = h   # MUTANT|' "$CAP" > "$TMP/cap-hostgroup.sh"
grep -q 'MUTANT' "$TMP/cap-hostgroup.sh" && r=0 || r=1
ck "m2: the mutant really lost the (host, boxid) key (the reader groups by hostname again)" "$r"
M2IN="$(printf 'aaa\trefs/boxes/cmux/10.238.144.2/%s-4-56-0-120000-14000-400-15641-1-%s\nbbb\trefs/boxes/cmux/10.238.144.3/%s-8-6100-0-120000-14000-400-15641-1-%s\n' "$NOW" "$A_BOOT" "$NOW" "$B_BOOT")"
_n_mut="$( ( . "$TMP/cap-hostgroup.sh"; printf '%s\n' "$M2IN" | cap_parse_lsremote ) | grep -c '^host=cmux ' )"
_n_fix="$( ( . "$CAP";                 printf '%s\n' "$M2IN" | cap_parse_lsremote ) | grep -c '^host=cmux ' )"
ck "m2: the MUTANT reader collapses two cmux boxes to 1 record ($_n_mut), the fix reads 2 ($_n_fix)" \
   "$([ "$_n_mut" -eq 1 ] && [ "$_n_fix" -eq 2 ] && echo 0 || echo 1)"
# (m3) drop the collision arm from cap_place => a marked record is PLACED instead of refused.
sed 's|^  if \[ "\$coll" -gt 0 \]; then$|  if false; then   # MUTANT|' "$CAP" > "$TMP/cap-nocollision.sh"
grep -q 'MUTANT' "$TMP/cap-nocollision.sh" && r=0 || r=1
ck "m3: the mutant really lost the collision refusal (cap_place ignores the reader mark)" "$r"
MARKED="host=cmux ncpu=4 load1=56 lpc=14 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=$NOW procs=400 procs_max=15641 fork=1 boxid=10.238.144.2 boot=$A_BOOT collide=1"
_rc_mut="$( ( . "$TMP/cap-nocollision.sh"; printf '%s\n' "$MARKED" | cap_place cmux ) >/dev/null 2>&1; echo $? )"
_rc_fix="$( ( . "$CAP";                 printf '%s\n' "$MARKED" | cap_place cmux ) >/dev/null 2>&1; echo $? )"
ck "m3: the MUTANT places on a collided record (rc=$_rc_mut), the fix REFUSES it (rc=$_rc_fix)" \
   "$([ "$_rc_mut" -eq 0 ] && [ "$_rc_fix" -eq 1 ] && echo 0 || echo 1)"
# (m4) restore the ROUND-2 inference (`same key => mine`) => the §13 peer ref is deleted again.
# ⛔ THIS IS THE MOST IMPORTANT CONTROL IN THE FILE: it re-creates the exact defect review round 2
# found, so the §13 arm is measured against the bug rather than against itself. The mutant is the
# SHIPPED file with the ledger clause replaced by the inference the first draft actually shipped.
sed 's|^  cap_ledger_has "\$ledger" "\$oref" && return 0.*$|  [ "$(cap_kv "$orec" boxid)" = "${CAP_MUT_BOXID:-}" ] \&\& return 0   # MUTANT: round-2 inference|' \
  "$CAP" > "$TMP/cap-infer.sh"
ck "m4: the mutant really lost the ledger proof (same key => deletable again; the round-2 shape)" \
   "$([ "$(grep -c 'MUTANT: round-2 inference' "$TMP/cap-infer.sh")" -eq 1 ] && echo 0 || echo 1)"
O7="$TMP/origin-m4.git"; W7="$TMP/work-m4"
git init -q --bare "$O7" >/dev/null 2>&1; git init -q "$W7" >/dev/null 2>&1
( cd "$W7" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O7" && git push -q origin HEAD:main ) >/dev/null 2>&1
m4pub() { _m_mod="$1"; _m_state="$2"; _m_ncpu="$3"; _m_at="$4"
  ( . "$_m_mod"; PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$_m_state" CAP_MUT_BOXID=10.238.144.2
    cap_hw_uuid() { return 1; }; cap_boxid_net() { printf '10.238.144.2'; }
    cap_ncpu() { printf '%s' "$_m_ncpu"; }; cap_boot_epoch() { printf '%s' "$SHARED_BOOT"; }
    cap_load1_100() { printf '56'; }
    CAP_NOW="$_m_at" cap_probe_local "$W7" 0 2>/dev/null > "$TMP/m4rec"
    CAP_NOW="$_m_at" cap_publish "$W7" "$(cat "$TMP/m4rec")" ) >/dev/null 2>&1; }
m4pub "$TMP/cap-infer.sh" "$TMP/state-m4a" 4 "$NOW"
m4pub "$TMP/cap-infer.sh" "$TMP/state-m4b" 8 "$(( NOW + 60 ))"
_n_m4="$(git -C "$W7" ls-remote --refs origin 'refs/boxes/*' | grep -c .)"
# the SAME two publishes against the SHIPPED file, on its own origin (a fresh repo, so the mutant's
# leftover ref cannot be counted as the fix's work).
O8="$TMP/origin-m4fix.git"; W8="$TMP/work-m4fix"
git init -q --bare "$O8" >/dev/null 2>&1; git init -q "$W8" >/dev/null 2>&1
( cd "$W8" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$O8" && git push -q origin HEAD:main ) >/dev/null 2>&1
m4pubx() { _m_mod="$1"; _m_state="$2"; _m_ncpu="$3"; _m_at="$4"
  ( . "$_m_mod"; PATH="$HB:$PATH" CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$_m_state" CAP_MUT_BOXID=10.238.144.2
    cap_hw_uuid() { return 1; }; cap_boxid_net() { printf '10.238.144.2'; }
    cap_ncpu() { printf '%s' "$_m_ncpu"; }; cap_boot_epoch() { printf '%s' "$SHARED_BOOT"; }
    cap_load1_100() { printf '56'; }
    CAP_NOW="$_m_at" cap_probe_local "$W8" 0 2>/dev/null > "$TMP/m4recc"
    CAP_NOW="$_m_at" cap_publish "$W8" "$(cat "$TMP/m4recc")" ) >/dev/null 2>&1; }
m4pubx "$CAP" "$TMP/state-m4c" 4 "$NOW"
m4pubx "$CAP" "$TMP/state-m4d" 8 "$(( NOW + 60 ))"
_n_fix4="$(git -C "$W8" ls-remote --refs origin 'refs/boxes/*' | grep -c .)"
ck "m4: the MUTANT collapses a shared-key peer to 1 ref ($_n_m4), the fix keeps 2 ($_n_fix4)" \
   "$([ "$_n_m4" -eq 1 ] && [ "$_n_fix4" -eq 2 ] && echo 0 || echo 1)"

# ── §14 THE BOX'S OWN IDENTITY (#3167): `scope global` is NOT a routability test ───────────────
echo
echo "── §14 box identity: the routable address, or an honest refusal — never `NR==1` ──"
# MEASURED 2026-10-31 on every cloud cell — the SAME arrangement on each (`ip -4 -o addr show scope
# global`), with `ip route show default` naming `eth0`:
#   3: eth0      inet 169.254.77.2/30  scope global  <-- RFC 3927 link-local, reported `scope global`
#   4: docker0   inet 172.17.0.1/16    scope global  <-- a bridge, at a LOWER ifindex than the real one
#   5: eth0.1911 inet 10.238.144.N/20  scope global  <-- THE identity
# The pre-#3167 body took `NR==1`, committed to line 3, rejected it in the tail guard, and returned 1
# with line 5 never read — so every cell published NO identity, `cap_publish` refused it by name, and
# every cell was permanently INELIGIBLE while the Mac (which resolves identity from Darwin `kern.uuid`)
# was the fleet's only eligible box. These arms drive the SHIPPED `cap_boxid_net` through a stubbed
# `ip`, so the PREDICATE is graded rather than a re-implementation of it.
IPB="$TMP/bin-ip"; mkdir -p "$IPB"
# ⛔ THE STUB HONOURS BOTH OF `ip`'s FILTERS the way real `ip` does (review rounds 6 and 10): a DOWN
# interface keeps its address in the listing (so `show up` must serve a SMALLER file), and `scope global`
# must filter too — a query WITHOUT it is served a host-scope listing, so deleting the scope filter from
# the shipped query cannot look correct here.
printf '#!/bin/sh\ncase "$*" in\n  *"route show default"*) cat "%s" ;;\n  *"scope global"*" up"*|*" up"*"scope global"*) cat "%s" ;;\n  *"scope global"*) cat "%s" ;;\n  *) cat "%s" ;;\nesac\n' \
  "$TMP/iproute.out" "$TMP/ipaddr.up.out" "$TMP/ipaddr.out" "$TMP/ipaddr.host.out" > "$IPB/ip"; chmod +x "$IPB/ip"
printf '1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n' > "$TMP/ipaddr.host.out"
# ipfix <egress-dev> <addr-line…> — one fixture for one box. `CAP_BOXID` is cleared in every arm below:
# the operator seam must not mask the derivation, which is the thing under test.
# ⛔ EACH ADDR LINE IS EMITTED IN THE PRODUCTION SHAPE, tail included (`\       valid_lft forever
# preferred_lft forever` — measured on a live cell: NF=13 and `$NF` is `forever`). A fixture without the
# tail is NF=9 with `$NF=eth0`, so an implementation that reads the LAST field instead of `$4` would be
# GREEN here and wrong on every real box — review round 1, finding 4.
# ⛔ AND SO IS THE ROUTE LINE (review round 3, finding 1): a DHCP-configured box prints
# `default via 10.9.9.1 dev wan0 proto dhcp src 10.9.9.9 metric 100` — the device is NOT the last field,
# so a `$NF` implementation loses the identity on an ordinary box. The `proto/src/metric` tail is part of
# the fixture for exactly that reason.
ipfix() { _d="$1"; shift; printf 'default via 169.254.77.1 dev %s proto dhcp src 169.254.77.2 metric 100\n' "$_d" > "$TMP/iproute.out"
  : > "$TMP/ipaddr.out"
  for _l in "$@"; do printf '%s\\       valid_lft forever preferred_lft forever\n' "$_l" >> "$TMP/ipaddr.out"; done
  cp "$TMP/ipaddr.out" "$TMP/ipaddr.up.out"; }
# ipfixdown <addr-line…> — append addresses that `ip … show up` would NOT list (a DOWN interface).
ipfixdown() { for _l in "$@"; do printf '%s\\       valid_lft forever preferred_lft forever\n' "$_l" >> "$TMP/ipaddr.out"; done; }
# ipfixr <route-line…> — replace just the ROUTE output (a multipath default is several lines; the address
# fixture is whatever the previous `ipfix` wrote).
ipfixr() { printf '%s\n' "$@" > "$TMP/iproute.out"; }
boxidnet_mod() { _m="$1"; ( . "$_m"; PATH="$IPB:$PATH"; CAP_BOXID=""; cap_boxid_net ) 2>/dev/null; }
boxidnet() { boxidnet_mod "$CAP"; }
if [ -r /proc/net/route ]; then
  # (1) the CELL's measured fixture: link-local FIRST, the docker bridge SECOND, the routable VLAN
  # child LAST — the exact arrangement `NR==1` died on.
  ipfix eth0 \
    '3: eth0    inet 169.254.77.2/30 brd 169.254.77.3 scope global eth0' \
    '4: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0' \
    '5: eth0.1911    inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0.1911'
  A1="$(boxidnet)"; RC=$?
  ck "(1) a cell whose FIRST global line is link-local and whose bridge is second resolves to the ROUTABLE one (boxid=$A1)" \
     "$([ "$RC" -eq 0 ] && [ "$A1" = 10.238.144.2 ] && echo 0 || echo 1)"
  # (2) nothing but link-local => REFUSE, never guess.
  ipfix eth0 '3: eth0 inet 169.254.77.2/30 brd 169.254.77.3 scope global eth0'
  A2="$(boxidnet)"; RC=$?
  ck "(2) a box whose ONLY 'global' address is link-local REFUSES (rc=$RC, boxid=[$A2]) — never a guess" \
     "$([ "$RC" -eq 1 ] && [ -z "$A2" ] && echo 0 || echo 1)"
  # (2b) …and a container bridge never names the box, even when it is the only plausible-looking
  # address on it: a bridge address is the FALSE-ATTRIBUTION direction, which is worse than refusing.
  ipfix eth0 \
    '3: eth0 inet 169.254.77.2/30 brd 169.254.77.3 scope global eth0' \
    '4: docker0 inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0'
  A2B="$(boxidnet)"; RC=$?
  ck "(2b) a link-local NIC plus a 172.17.0.1 docker bridge REFUSES rather than adopting the bridge (rc=$RC, boxid=[$A2B])" \
     "$([ "$RC" -eq 1 ] && [ -z "$A2B" ] && echo 0 || echo 1)"
  # (3) SEVERAL real addresses => a stable, documented choice, and the SAME one on every run ($C1/$C2)
  # and whatever order `ip` emitted the lines in ($C3) — a boxid that FLAPS publishes false attribution.
  ipfix eth0 \
    '3: eth0 inet 10.1.0.5/24 brd 10.1.0.255 scope global eth0' \
    '5: eth0.7 inet 10.2.0.7/24 brd 10.2.0.255 scope global eth0.7'
  A3="$(boxidnet)"; RC=$?
  A3B="$(boxidnet)"
  ck "(3) a box with SEVERAL real addresses picks the documented one (lowest ifindex => $A3) and again on the next run ($A3B)" \
     "$([ "$RC" -eq 0 ] && [ "$A3" = 10.1.0.5 ] && [ "$A3B" = 10.1.0.5 ] && echo 0 || echo 1)"
  ipfix eth0 \
    '5: eth0.7 inet 10.2.0.7/24 scope global eth0.7' \
    '3: eth0 inet 10.1.0.5/24 brd 10.1.0.255 scope global eth0'
  A3C="$(boxidnet)"; RC=$?
  ck "  …and the SAME one when \`ip\` lists them in the other order ($A3C) — the answer is a function of the set, not of the output order" \
     "$([ "$RC" -eq 0 ] && [ "$A3C" = 10.1.0.5 ] && echo 0 || echo 1)"
  # (3b) THE IFINDEX ORDER DECIDES, NOT THE ADDRESS ORDER (review round 3, finding 4). Here the lower
  # ifindex holds the HIGHER address, so the documented rule (lowest ifindex) and an octet-only rule
  # disagree. ⛔ THE IFINDEXES STRADDLE A DIGIT BOUNDARY (9 vs 12) ON PURPOSE (review round 11): the parse
  # coerces to a number (`i = i + 0`), and without it awk compares "12" < "9" as STRINGS and the rule
  # inverts — which every single-digit fixture in this section cannot see.
  ipfix eth0 \
    '9: eth0 inet 10.2.0.7/24 brd 10.2.0.255 scope global eth0' \
    '12: eth0.1911 inet 10.1.0.5/24 scope global eth0.1911'
  A3D="$(boxidnet)"; RC=$?
  ck "  …and the LOWEST IFINDEX wins even when it holds the numerically HIGHER address ($A3D, not 10.1.0.5) — and across a digit boundary (9 vs 12)" \
     "$([ "$RC" -eq 0 ] && [ "$A3D" = 10.2.0.7 ] && echo 0 || echo 1)"
  # (4) no address at all => refuse.
  ipfix eth0 ''
  A4="$(boxidnet)"; RC=$?
  ck "(4) a box with NO address at all REFUSES (rc=$RC, boxid=[$A4])" \
     "$([ "$RC" -eq 1 ] && [ -z "$A4" ] && echo 0 || echo 1)"
  # (5) MUTATION CONTROL — the PRE-#3167 body, cited verbatim from the commit this fixes, run on
  # fixture (1). If this arm ever answers an identity, the arms above stopped discriminating.
  { cat "$CAP"; cat <<'MUT'
# MUTANT (m5): the PRE-#3167 Linux arm, verbatim: `NR==1` of `ip -o addr show scope global`.
cap_boxid_net() {
  local out ifc ip
  if command -v ip >/dev/null 2>&1 && [ -r /proc/net/route ]; then
    out="$(ip -4 -o addr show scope global 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    ifc="$(printf '%s\n' "$out" | awk 'NR==1{print $2}')"
    ip="$(printf '%s\n' "$out" | awk 'NR==1{print $4}')"
    ip="${ip%%/*}"
  else
    return 1
  fi
  case "$ip" in ''|*[!0-9.]*) return 1 ;; esac
  case "$ip" in 127.*|169.254.*) return 1 ;; esac
  printf '%s' "$ip"
}
MUT
  } > "$TMP/cap-nr1.sh"
  ipfix eth0 \
    '3: eth0    inet 169.254.77.2/30 brd 169.254.77.3 scope global eth0' \
    '4: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0' \
    '5: eth0.1911    inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0.1911'
  M5="$(boxidnet_mod "$TMP/cap-nr1.sh")"; RC=$?
  ck "(5) m5: the PRE-#3167 body yields NO identity on the very fixture (1) answers ($M5, rc=$RC) — arm (1) is RED before this fix" \
     "$([ "$RC" -eq 1 ] && [ -z "$M5" ] && echo 0 || echo 1)"
  # (8) CLAUSE 1 IS LOAD-BEARING (review round 1, finding 1). A foreign device with a name the reject
  # list does NOT name (`br0` — a bridge, or a VPN's `bond0`) is at a LOWER ifindex than the egress
  # device, and carries the container-network address. Only the egress anchor rejects it; delete clause 1
  # and this arm returns 172.17.0.1 — the false attribution this whole change exists to prevent.
  ipfix eth0 \
    '2: br0 inet 172.17.0.1/16 brd 172.17.255.255 scope global br0' \
    '3: eth0 inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0'
  A8="$(boxidnet)"; RC=$?
  ck "(8) a NON-REJECTED-NAME foreign device at a LOWER ifindex is never the identity (got $A8) — the egress anchor is what rejects it" \
     "$([ "$RC" -eq 0 ] && [ "$A8" = 10.238.144.2 ] && echo 0 || echo 1)"
  # (8b) …and the child test is ANCHORED TO THE PREFIX (review round 10, finding 2): a device whose name
  # merely CONTAINS the egress name (`fooeth0.9`) is a foreign device, not a VLAN child. Loosening
  # `index($2, dev ".") != 1` to a substring test published `192.0.2.79` here with the suite green.
  ipfix eth0 \
    '3: fooeth0.9 inet 192.0.2.79/24 brd 192.0.2.255 scope global fooeth0.9' \
    '4: eth0.1911 inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0.1911'
  A8B="$(boxidnet)"; RC=$?
  ck "(8b) a device whose name only CONTAINS the egress name is not a VLAN child ($A8B, not 192.0.2.79)" \
     "$([ "$RC" -eq 0 ] && [ "$A8B" = 10.238.144.2 ] && echo 0 || echo 1)"
  # (8c) …and the '.' in that anchor is LOAD-BEARING (review round 12): a device named `eth01` STARTS WITH
  # the egress name, so dropping the dot from the anchor let it pass at a lower ifindex and published its
  # address — a false attribution — with the suite green. (8b) cannot see this: `fooeth0.9` fails both forms.
  ipfix eth0 \
    '3: eth01 inet 192.0.2.79/24 brd 192.0.2.255 scope global eth01' \
    '5: eth0.1911 inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0.1911'
  A8C="$(boxidnet)"; RC=$?
  ck "(8c) a device that merely STARTS WITH the egress name (\`eth01\`) is not its VLAN child ($A8C, not 192.0.2.79) — the dot is load-bearing" \
     "$([ "$RC" -eq 0 ] && [ "$A8C" = 10.238.144.2 ] && echo 0 || echo 1)"
  # (20) A BOX WHOSE DEFAULT ROUTE NAMES NO DEVICE IS REFUSED (review round 13). The `[ -n "$dev" ]` guard
  # is NOT a no-op: with an empty `dev`, clause 1 degenerates to `index($2, ".") != 1`, which a device named
  # `.foo` PASSES (the kernel accepts such a name) — so without the guard that box publishes a non-egress
  # address. Measured shape: device `.foo` at a low ifindex, default route present but device-less.
  ipfix eth0 '3: .foo inet 10.77.0.9/24 brd 10.77.0.255 scope global .foo'
  ipfixr 'blackhole default'
  A20="$(boxidnet)"; RC=$?
  ck "(20) a box whose default route names NO device REFUSES (rc=$RC, boxid=[$A20]) — the empty-egress guard is load-bearing, not a no-op" \
     "$([ "$RC" -eq 1 ] && [ -z "$A20" ] && echo 0 || echo 1)"
  # (9) AND CLAUSE 2 IS LOAD-BEARING (same finding). The EGRESS device itself is a tunnel (`wg0`): its
  # address satisfies the anchor and is routable-looking, so only the name clause refuses it.
  ipfix wg0 '3: wg0 inet 10.8.0.2/24 peer 10.8.0.1/32 scope global wg0'
  A9="$(boxidnet)"; RC=$?
  ck "(9) an egress device that is a TUNNEL refuses rather than adopting its address (rc=$RC, boxid=[$A9])" \
     "$([ "$RC" -eq 1 ] && [ -z "$A9" ] && echo 0 || echo 1)"
  # (10) TWO addresses on ONE device (review round 1, finding 2; round 2, finding 1; round 3, finding 3).
  # (a) a `secondary` address never displaces the address of record. ⛔ THE SECONDARY LINE COMES FIRST
  #     ON PURPOSE: with the primary first, the `s == bs` guard inside the numeric term already refuses
  #     the displacement and the `s < bs` clause grades nothing (round 3 measured exactly that).
  #     ⛔ WHAT THE KERNEL DOES (round 4 corrected three wrong claims that stood here): a plain second
  #     `ip addr add 10.1.0.9/24 dev eth0` — no keyword, no label — is printed as `scope global
  #     secondary`; `ip addr add … secondary` is ACCEPTED by iproute2 6.x with a warning and lands the
  #     same way; and a labelled alias reports `secondary: true, label: 'eth0:1'` in `ip -j addr show`.
  #     So the flag is a real shape, and this fixture is in that shape (the label trails, `$2` is the
  #     device).
  ipfix eth0 \
    '3: eth0 inet 10.9.9.9/24 brd 10.9.9.255 scope global secondary eth0:1' \
    '3: eth0 inet 192.168.7.5/24 brd 192.168.7.255 scope global eth0'
  A10="$(boxidnet)"; RC=$?
  # (b) …and the tie-break among candidates that are equal in BOTH ifindex and secondary-ness is
  #     NUMERIC. THREE addresses, chosen so that every wrong rule gives a DIFFERENT answer from the octet
  #     rule (review round 6, finding 1 measured that two addresses could not: with the lowest one first,
  #     "first wins" — the numeric term deleted — agrees with the octet answer, so the term's EXISTENCE
  #     was ungraded; with the lowest one last, "last wins" agreed instead):
  #        octets    ⇒ 10.9.9.10   (the numeric minimum)
  #        string    ⇒ 10.9.10.9   ("10.9.10.9" < "10.9.9.10")
  #        first-wins (no numeric term) ⇒ 10.9.10.9
  #        last-wins                    ⇒ 10.9.9.11
  ipfix eth0 \
    '3: eth0 inet 10.9.10.9/24 brd 10.9.10.255 scope global eth0' \
    '3: eth0 inet 10.9.9.10/24 brd 10.9.9.255 scope global eth0' \
    '3: eth0 inet 10.9.9.11/24 brd 10.9.9.255 scope global eth0'
  A10B="$(boxidnet)"
  ck "(10) a secondary never displaces the primary ($A10), and the tie-break is NUMERIC — octets give .9.10, a string compare gives .10.9 ($A10B)" \
     "$([ "$RC" -eq 0 ] && [ "$A10" = 192.168.7.5 ] && [ "$A10B" = 10.9.9.10 ] && echo 0 || echo 1)"
  # (13) THE ROUTE LINE IS NOT ALWAYS ONE LINE (review round 5, finding 3): a multipath default dumps a
  # bare `default` record first and the devices only on the `nexthop` lines after it. A `NR==1` parse
  # therefore refuses on such a box (fail-closed, but a silent eligibility loss the comment at
  # capacity.sh:398-400 presents as handled) — round 5 measured it 211/0 green.
  ipfix eth0 '3: eth0 inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0'
  ipfixr 'default proto static' '\tnexthop via 169.254.77.1 dev eth0 weight 1' '\tnexthop via 169.254.77.1 dev eth9 weight 1'
  A13="$(boxidnet)"; RC=$?
  # …and several main-table defaults at different metrics: the FIRST (lowest metric, iproute2's own order).
  ipfix eth0 '3: eth0 inet 10.238.144.2/20 scope global eth0' '4: eth9 inet 10.9.9.9/24 scope global eth9'
  ipfixr 'default via 169.254.77.1 dev eth0 proto dhcp src 169.254.77.2 metric 100' 'default via 169.254.77.1 dev eth9 metric 200'
  A13B="$(boxidnet)"; RC2=$?
  ck "(13) a MULTIPATH default (bare first line, devices on the nexthop lines) still yields the egress device's address ($A13), and several defaults use the lowest metric ($A13B)" \
     "$([ "$RC" -eq 0 ] && [ "$A13" = 10.238.144.2 ] && [ "$RC2" -eq 0 ] && [ "$A13B" = 10.238.144.2 ] && echo 0 || echo 1)"
  # (14) A DOWN INTERFACE IS NOT A PEER-REACHABLE ADDRESS (review round 6, finding 2). The dead VLAN holds
  # its stale address at a LOWER ifindex and passes every other clause, so only the `up` filter rejects it.
  ipfix eth0 '5: eth0.1911 inet 10.238.144.2/20 brd 10.238.159.255 scope global eth0.1911'
  ipfixdown '4: eth0.100 inet 192.168.99.7/24 brd 192.168.99.255 scope global eth0.100'
  A14="$(boxidnet)"; RC=$?
  ck "(14) an address on a DOWN interface is never the identity ($A14 — the dead VLAN is at a LOWER ifindex)" \
     "$([ "$RC" -eq 0 ] && [ "$A14" = 10.238.144.2 ] && echo 0 || echo 1)"
  # (15) AN EGRESS-CARRYING PSEUDO/CONTAINER/TUNNEL DEVICE: clause 1 accepts the egress device by
  # definition, so the name deny-list is the ONLY filter that can refuse — and each round of review found
  # entries that were individually ungraded, i.e. that deleting one was silent (round 7: five of six new
  # entries; round 8: `docker` and `br-`, whose measured consequence is that a docker host with
  # `default via … dev docker0` publishes `172.17.0.1` as its identity). So EVERY entry in the list is fed
  # here, in the POINTOPOINT shape real `ip` prints for the tunnels (`inet X peer Y/32` — no `brd`).
  A15BAD=""
  for _tn in lo docker0 br-1a2b3c4d veth0 virbr0 podman0 vxlan0 cni0 flannel.1 cali1 kube-ipvs0 \
             tun0 tap0 wg0 zt0 tailscale0 utun3 ppp0 gre1 ipip0 sit0 wwan0 rmnet0 dummy0 lxcbr0; do
    ipfix "$_tn" "2: $_tn inet 10.8.0.2/24 peer 10.8.0.1/32 scope global $_tn"
    _tv="$(boxidnet)"; _trc=$?
    { [ "$_trc" -eq 1 ] && [ -z "$_tv" ]; } || A15BAD="$A15BAD $_tn=[$_tv]"
  done
  ck "(15) EVERY entry in the deny list refuses as an EGRESS device rather than adopting its address (25 names: lo, docker0, br-, veth, virbr, podman, vxlan, cni, flannel, cali, kube, tun, tap, wg, zt, tailscale, utun, ppp, gre, ipip, sit, wwan, rmnet, dummy, lxc)${A15BAD:+ — FAILED:}$A15BAD" \
     "$([ -z "$A15BAD" ] && echo 0 || echo 1)"
  # each is addable on this kernel and each appears in `ip -4 -o addr show scope global` (measured under
  # `unshare -rn`), so a clause that drops one publishes an address no peer can use as an identity.
  # ⛔ BOTH HALVES OF THE RESERVED RANGE ARE FED: `224.0.0.7` only exercises `22[4-9]\.` (224-229), so
  # round 4 measured that dropping `2[3-5][0-9]\.` (230-255) stayed green while the mutant published
  # `239.0.0.1`. `239.0.0.1` is in 224/4 (multicast) and is that alternative's own slice.
  ipfix eth0 '3: eth0 inet 0.9.9.9/24 scope global eth0'
  A11="$(boxidnet)"; RC=$?
  ipfix eth0 '3: eth0 inet 224.0.0.7/24 scope global eth0'
  A11B="$(boxidnet)"; RC2=$?
  ipfix eth0 '3: eth0 inet 239.0.0.1/24 scope global eth0'
  A11C="$(boxidnet)"; RC3=$?
  ck "(11) unspecified (0/8) and BOTH halves of the reserved range (224-229, 230-255) REFUSE rather than being published ([$A11] rc=$RC, [$A11B] rc=$RC2, [$A11C] rc=$RC3)" \
     "$([ "$RC" -eq 1 ] && [ -z "$A11" ] && [ "$RC2" -eq 1 ] && [ -z "$A11B" ] && [ "$RC3" -eq 1 ] && [ -z "$A11C" ] && echo 0 || echo 1)"
else
  # ⛔ THE LIST IS DERIVED, NOT TYPED (review round 14): it went stale twice as arms were added inside the
  # Linux-only branch, so a reader was told (14), (15) and (20) ran on macOS when they had not.
  SKIPLIST="$(awk '
    /^if \[ -r \/proc\/net\/route \]; then/ { f=1; next }
    f && /^else$/ { exit }
    f && /ck "/ {
      if (match($0, /\([0-9]+[a-z]?\)/)) { t = substr($0, RSTART, RLENGTH); if (!(t in seen)) { seen[t]=1; printf "%s ", t } }
    }' "$0" 2>/dev/null)"
  [ -n "$SKIPLIST" ] || SKIPLIST="(1)-(5) (8)-(11) (13)-(15) (20)"
  echo "  ⏭ §14 ${SKIPLIST}SKIPPED: this platform has no /proc/net/route, so the LINUX arm of cap_boxid_net"
  echo "    is unreachable here. Arm (12) — the DARWIN arm, the one this platform actually uses — runs below."
fi
# (12) THE DARWIN ARM (review round 5, finding 2: it used to sit INSIDE the Linux-only branch, so the
# branch a Mac actually uses was ungraded ON the Mac). It needs no procfs: it is reached the way a Mac
# reaches it, by there being no `ip` on PATH, so it runs on both platforms.
DAB="$TMP/bin-darwin"; mkdir -p "$DAB"
printf '#!/bin/sh\necho "  interface: eth9"\n' > "$DAB/route"
printf '#!/bin/sh\necho cmux\n' > "$DAB/hostname"
printf '#!/bin/sh\necho Linux\n' > "$DAB/uname"
chmod +x "$DAB/route" "$DAB/hostname" "$DAB/uname"
[ -e "$DAB/awk" ] || ln -s "$(command -v awk)" "$DAB/awk" 2>/dev/null || true
# ⛔ the ifconfig stub BAKES its answer in: an exported variable would not survive the restricted PATH.
da_ifconfig() { printf '#!/bin/sh\nprintf "\\tinet %s netmask 0xffff0000\\n"\n' "$1" > "$DAB/ifconfig"; chmod +x "$DAB/ifconfig"; }
boxidnet_darwin() ( da_ifconfig "$1"; PATH="$DAB"; CAP_BOXID=""; . "$CAP"; cap_boxid_net ) 2>/dev/null
A12="$(boxidnet_darwin 10.238.144.2)"; RC=$?
A12B="$(boxidnet_darwin 169.254.7.7)"; RC2=$?
# ⛔ AND THE LOOPBACK BRANCH OF THE SAME GUARD (review round 11): the Darwin path has no `scope global`
# filter at all, so `127/8` rejection there rests ENTIRELY on that `case` — ungraded until now.
A12C="$(boxidnet_darwin 127.0.0.1)"; RC3=$?
ck "(12) the Darwin arm (no \`ip\` on PATH — runs on macOS too) answers its interface address ($A12), REFUSES a link-local one (rc=$RC2, boxid=[$A12B]) and REFUSES a loopback one (rc=$RC3, boxid=[$A12C])" \
   "$([ "$RC" -eq 0 ] && [ "$A12" = 10.238.144.2 ] && [ "$RC2" -eq 1 ] && [ -z "$A12B" ] && [ "$RC3" -eq 1 ] && [ -z "$A12C" ] && echo 0 || echo 1)"
# (21) A MALFORMED `ifconfig` SHAPE IS REFUSED, not adopted (review round 13): net-tools/BusyBox print
# `inet addr:10.1.2.3`, so `awk '{print $2}'` yields `addr:10.1.2.3` — a NON-ADDRESS string. The tail
# guard's `*[!0-9.]*` arm is the only thing refusing it, so it is graded here.
A21="$(boxidnet_darwin 'addr:10.1.2.3')"; RC=$?
# ⛔ AND AN ADDRESS THAT IS ENTIRELY ABSENT (review round 14): an IPv6-only interface prints no `inet` line,
# so `awk` yields the EMPTY string and only the tail case's `''` branch refuses it. Measured: with that
# branch dropped the function returns 0 with an empty boxid — a successful "publish" of nothing.
da_noinet() { printf '#!/bin/sh\nprintf "\\tinet6 fe80::1%%en0 prefixlen 64\\n"\n' > "$DAB/ifconfig"; chmod +x "$DAB/ifconfig"; }
A21B="$( da_noinet; PATH="$DAB"; CAP_BOXID=""; . "$CAP"; cap_boxid_net 2>/dev/null )"; RC4=$?
ck "(21) a NON-ADDRESS token (addr:10.1.2.3) REFUSES (rc=$RC, boxid=[$A21]) and so does an ABSENT one (IPv6-only interface: rc=$RC4, boxid=[$A21B])" \
   "$([ "$RC" -eq 1 ] && [ -z "$A21" ] && [ "$RC4" -eq 1 ] && [ -z "$A21B" ] && echo 0 || echo 1)"
# (6) THE REFUSAL IS READABLE. `cap_publish` is fail-closed by design and prints `why=<reason>`; the
# controller discarded it, which is why this took a whole lane to find. Text guard: the reason must
# reach the log line (a discarded refusal is the defect class, not a cosmetic detail).
ck "(6) the controller REALLY CALLS the logging publish (not a local re-implementation, and not the silent form)" \
   "$(grep -qF -- 'cap_publish_logged "$REPO" "$CAP_REC" "$LOG" "$CAP_NS"' "$LOOP" && echo 0 || echo 1)"
# (16)-(18) THE DIAGNOSTIC IS GRADED AS BEHAVIOUR (review round 9, finding 1). Text greps for fragments
# were the defect: the reason PARSING could be neutered (`why=unknown` for a real `no-box-identity`), the
# field could be read as `$NF` (a push refusal then reports the ref as the reason), and the block's
# POLARITY could be flipped (`&&`), all with the suite green. So the shipped `cap_publish_logged` is driven
# against a local bare origin instead.
O16="$TMP/origin-log.git"; W16="$TMP/work-log"
( git init -q --bare "$O16" && git init -q "$W16" && cd "$W16" && git config user.email t@t \
  && git config user.name t && git commit -q --allow-empty -m init && git remote add origin "$O16" \
  && git push -q origin HEAD:main ) >/dev/null 2>&1
LOGL="$TMP/cap-log.txt"
VALID="host=cmux ncpu=4 load1=56 lpc=14 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=$NOW procs=400 procs_max=15641 fork=1 boot=$A_BOOT"
: > "$LOGL"
RC=0; CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/state-log1" cap_publish_logged "$W16" "$VALID" "$LOGL" refs/boxes || RC=$?
L16="$(cat "$LOGL" 2>/dev/null)"
ck "(16) a refused publish (no boxid) returns 1 and its log line NAMES the reason — why=no-box-identity, plus the CAP_BOXID seam (rc=$RC)" \
   "$([ "$RC" -eq 1 ] && qF 'why=no-box-identity' "$L16" && qF 'the operator seam is CAP_BOXID' "$L16" && echo 0 || echo 1)"
# an invalid record (a valid boxid, but `fork=` is not a number) — a DIFFERENT reason, so the remedy must
# NOT be offered (pointing the operator at a boxid that is already right is a misdiagnosis).
L16REC="host=cmux ncpu=4 load1=56 lpc=14 lanes=0 disk_free_mb=120000 mem_free_mb=14000 at=$NOW procs=400 procs_max=15641 fork=x boot=$A_BOOT boxid=10.238.144.2"
: > "$LOGL"
RC=0; CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/state-log3" cap_publish_logged "$W16" "$L16REC" "$LOGL" refs/boxes || RC=$?
L17="$(cat "$LOGL" 2>/dev/null)"
ck "(17) a DIFFERENT refusal reason is named (why=invalid-record) and the CAP_BOXID remedy is NOT offered (rc=$RC)" \
   "$([ "$RC" -eq 1 ] && qF 'why=invalid-record' "$L17" && ! qF 'the operator seam is CAP_BOXID' "$L17" && echo 0 || echo 1)"
: > "$LOGL"
RC=0; CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/state-log4" cap_publish_logged "$W16" "$VALID boxid=10.238.144.2" "$LOGL" refs/boxes || RC=$?
ck "(18) a SUCCESSFUL publish returns 0 and writes NO refusal line (rc=$RC, log bytes=$(wc -c < "$LOGL" | tr -d ' ')) — the polarity cannot be inverted silently" \
   "$([ "$RC" -eq 0 ] && [ ! -s "$LOGL" ] && echo 0 || echo 1)"
# (19) A PUSH FAILURE carries MORE on the line (`publish=failed why=push-refused ref=refs/boxes/...`), so
# the reason must be read FIELD-ANCHORED: `$NF` would report the ref as the reason (review round 9).
W17="$TMP/work-log-bad"; git init -q "$W17"; ( cd "$W17" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git remote add origin "$TMP/does-not-exist.git" ) >/dev/null 2>&1
: > "$LOGL"
RC=0; CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/state-log5" cap_publish_logged "$W17" "$VALID boxid=10.238.144.2" "$LOGL" refs/boxes || RC=$?
L19="$(cat "$LOGL" 2>/dev/null)"
ck "(19) a PUSH failure is reported as why=push-refused — the ref on the line does NOT become the reason (rc=$RC)" \
   "$([ "$RC" -eq 1 ] && qF '— why=push-refused boxid=' "$L19" && ! qF '— why=push-refused ref=' "$L19" && echo 0 || echo 1)"
# (22) AN UNPARSEABLE refusal still names a reason (review round 13): `cap_publish` failing WITHOUT
# printing a `publish=refused|failed` line must log `why=unknown`, never an empty token — the whole point
# of this PR is that a refusal must never be silent-or-blank.
: > "$LOGL"
L22="$( CAP_HOST="" CAP_BOXID="" CAP_STATE_DIR="$TMP/state-log6" bash -c '
  . "$1"
  cap_publish() { return 1; }
  cap_publish_logged "$2" "$3" "$4" refs/boxes; echo "rc=$?"' _ "$CAP" "$W16" "$VALID boxid=10.238.144.2" "$LOGL" 2>&1 )"
ck "(22) a refusal that prints NO parsable line still logs why=unknown ($(grep -o 'why=[^ ]*' "$LOGL" | head -1)) — never a blank reason" \
   "$( { grep -q 'rc=1' <<<"$L22" && grep -q 'why=unknown' "$LOGL" && ! grep -q 'why= ' "$LOGL"; } && echo 0 || echo 1)"
# (7) THE MAC CANNOT BE AFFECTED. A Darwin box resolves its identity from `kern.uuid` FIRST
# (`cap_boxid_auto` source 1), so it never reaches the Linux arm this fix changes. That precedence is
# the property, not a comment: asserted here so a future edit that reorders the sources — or that makes
# the net arm authoritative — goes red on the box the fleet depends on today.
macbid() ( . "$CAP"; cap_hw_uuid() { printf '8e93de39-C0FFEE-11EE-9E93-8E93DE39AAAA'; }
  cap_boxid_net() { printf '10.238.144.2'; }
  CAP_BOXID=""; cap_boxid_auto )
MACBID="$(macbid 2>/dev/null)"; RC=$?
ck "(7) a box with a hardware uuid keeps THAT identity and never consults the net derivation (mac unchanged: $MACBID)" \
   "$([ "$RC" -eq 0 ] && [ "$MACBID" = '8e93de39-C0FFEE-11EE-9E93-8E93DE39AAAA' ] && echo 0 || echo 1)"


echo
echo "───────────────────────────────────────────────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
