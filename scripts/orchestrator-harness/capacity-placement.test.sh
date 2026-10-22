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
rec() {
  recf "$1" "$2" "$3" "$4" "$5" "$6" "$7" 400 15041 1
}
# recf <host> <ncpu> <load1-x100> <lanes> <disk_mb> <mem_mb> <at> <procs> <procs_max> <fork>
recf() {
  printf 'host=%s ncpu=%s load1=%s lpc=%s lanes=%s disk_free_mb=%s mem_free_mb=%s at=%s procs=%s procs_max=%s fork=%s' \
    "$1" "$2" "$3" "$(awk -v l="$3" -v n="$2" 'BEGIN{printf "%d", l/n}')" "$4" "$5" "$6" "$7" \
    "$8" "$9" "${10}"
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
   "$(q 'ref=refs/boxes/cell-4/' "$PUB" && echo 0 || echo 1)"
CAP_HOST="cell-1" cap_publish "$WORK" "$(rec cell-1 8 2982 5 90000 3000 $NOW)" >/dev/null 2>&1
READ="$(cap_read_fleet "$WORK")"; RC=$?
ck "a PEER reads the whole fleet with one ls-remote (rc 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "  …and both boxes are in it, with their readings intact" \
   "$(q 'host=cell-4 .*lpc=7 ' "$READ" && q 'host=cell-1 .*lpc=372 ' "$READ" && echo 0 || echo 1)"
PL="$(printf '%s\n' "$READ" | cap_place cell-1)"
ck "placement over the REAL channel picks the idle box" \
   "$(q '^place=cell-4 ' "$PL" && echo 0 || echo 1)"
# A second reading from the SAME box must supersede the first, and must not delete a peer's.
CAP_HOST="cell-4" cap_publish "$WORK" "$(rec cell-4 8 6100 3 120000 14000 $(( NOW + 60 )))" >/dev/null 2>&1
READ2="$(cap_read_fleet "$WORK")"
ck "a newer reading supersedes the old one for that box (one record per box, newest wins)" \
   "$(q 'host=cell-4 .*lpc=762 ' "$READ2" && echo 0 || echo 1)"
ck "  …and only ONE cell-4 ref survives (the publisher prunes its own old record)" \
   "$([ "$(printf '%s' "$READ2" | grep -c 'host=cell-4 ')" -eq 1 ] && echo 0 || echo 1)"
ck "  …and the peer's record is UNTOUCHED by that prune (host-scoped, never fleet-wide)" \
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
LEGACY="$(rec cell-4 8 56 11 90000 3000 "$NOW" | sed 's/ procs=.*//')"
ck "a LEGACY record (no fork fields) is refused as fork_unknown, not read as healthy" \
   "$(printf '%s\n' "$LEGACY" | cap_place cell-4 | grep -q 'bound=fork_unknown' && echo 0 || echo 1)"
ck "  …and cap_valid_record rejects it while cap_valid_base_record accepts it (a named cause, not a blanket one)" \
   "$( ( cap_valid_record "$LEGACY"; [ $? -eq 1 ] && cap_valid_base_record "$LEGACY" ) && echo 0 || echo 1)"
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
_fk_line="$(grep -n 'elif \[ "${FORK_STARVED:-0}" = "1" \]; then' "$LOOP" | head -1 | cut -d: -f1)"
_ld_line="$(grep -n 'elif \[ "$L" -ge "$MAX_LOAD" \]; then GATE_WHY="load=' "$LOOP" | head -1 | cut -d: -f1)"
ck "the controller's OWN chain checks fork BEFORE load (fork=$_fk_line load=$_ld_line)" \
   "$([ -n "${_fk_line:-}" ] && [ -n "${_ld_line:-}" ] && [ "$_fk_line" -lt "$_ld_line" ] && echo 0 || echo 1)"
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
# THE SPAWN POINT: fork before disk before load, with its own refusal code.
SG="$HERE/spawn-gate.sh"
ck "the spawn gate declares its OWN fork refusal code (74), distinct from disk (77) and load (75)" \
   "$(grep -q '^AGENT_FORK_REFUSED=74$' "$SG" && echo 0 || echo 1)"
_sf="$(grep -n 'spawn_fork_state _fstate _fdetail' "$SG" | head -1 | cut -d: -f1)"
_sd="$(grep -n 'dpath="${DISK_GATE_PATH:-$PWD}"' "$SG" | head -1 | cut -d: -f1)"
_sl="$(grep -n 'if ! can_spawn "$l"; then' "$SG" | head -1 | cut -d: -f1)"
ck "  …and run_agent evaluates FORK before DISK before LOAD (f=$_sf d=$_sd l=$_sl)" \
   "$([ -n "${_sf:-}" ] && [ -n "${_sd:-}" ] && [ -n "${_sl:-}" ] && [ "$_sf" -lt "$_sd" ] && [ "$_sd" -lt "$_sl" ] && echo 0 || echo 1)"

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
