#!/usr/bin/env bash
# ci-queue-cap.test.sh — THE CI QUEUE IS A GATE INPUT, and this suite is what makes that true.
#
# ⛔ THE DEFECT THIS PINS. Measured 2026-10-22 on daniel-ospina/tortoise: 29 open PRs, every one
# `MERGEABLE` with `reviewDecision: null`, zero failing checks, `statusCheckRollup: PENDING` on all of
# them — and 140 workflow runs QUEUED against 1 IN PROGRESS. The fleet out-produced CI verification by
# two orders of magnitude, so nothing could go green, nothing merged, and the controller reported
# `DRAIN STALLED` hours late. That line is the SYMPTOM of a gate that measured the PR COUNT (an
# outcome, lagging its own cause) and was blind to the CI QUEUE (the cause).
#
# WHAT IS ASSERTED, and why each arm exists:
#   T1  queued BELOW the bound        -> ceiling unchanged, and the [cap] line still SHOWS the depth
#   T2  queued ABOVE the bound        -> ceiling reduced AND the skip line NAMES the gate + the numbers
#   T3  the reduced ceiling's floor   -> never below 1 (a starved fleet cannot drain anything), and a
#                                        deliberate MAX_LANES=0 is never RAISED
#   T4  UNREADABLE queue              -> ceiling unchanged, `ci=UNREADABLE` on the [cap] line, no throttle
#   T5  the bound is a BOUND          -> == is not over it, the next one is; a non-default bound is read
#   T6  REST shape                    -> exactly two `gh api …actions/runs?status=…` calls, no GraphQL,
#                                        and a 200 whose body is NOT a number reads UNREADABLE
#   T7  the [cap] line is parseable   -> every pre-existing `key=value` survives, in order, one line
#   T8  the throttle is narrow        -> it names ci-congestion only, and the queue is read even when
#                                        nothing could be dispatched
#   T9  NON-VACUITY                   -> the throttle is disabled in a COPY and T2 is REQUIRED to fail
#
# HERMETIC: a stub `gh` on PATH, no network, no credentials, nothing written outside $TMP. The shipped
# functions are EXTRACTED FROM orch-loop.sh and DRIVEN — never re-implemented here, so this suite
# cannot drift from the code the daemon runs.
# ⛔ THE [cap] CONSUMERS WERE GREPPED FIRST (as the change requires): no program parses that line — it
# is `key=value`, read by humans and quoted in docs (scripts/orchestrator-harness/README.md §4/§6,
# docs/ops/fleet-harness-baseline.md §4). T7 therefore pins the SHAPE (prefix, one line, the full key
# set, order, the numeric `lanes=N/M` field), which is what "stays parseable" means for a line with no
# machine reader: an edit that drops, renames or reorders a field reddens here.
#
# USAGE
#   bash ci-queue-cap.test.sh
# ⛔ THE RED PROOF (T9) RUNS ON EVERY INVOCATION, not behind a flag: `run-bash-shards.sh` calls this
# suite with no arguments, and a red proof nobody passes the flag for is a gate that can be deleted
# (with its MUT-ANCHOR) while every shard stays green. It costs one extra pass of a ~1.5 s suite.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ⛔ OVERRIDABLE so the RED direction can be RE-MEASURED rather than believed:
#   LOOP=<a copy with the throttle removed> bash ci-queue-cap.test.sh
LOOP="${LOOP:-$HERE/orch-loop.sh}"
T="$(mktemp -d "${TMPDIR:-/tmp}/ci-queue-cap.XXXXXX")" || exit 2
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0; FAILED_IDS=""
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_IDS="$FAILED_IDS $2"; printf '  ❌ [%s] %s\n' "${2:-?}" "$1"; }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "${3:-?}"; fi; }
# assertion helpers — the `case` patterns live HERE, not inside a `$( )` (a `*)` written inside a
# command substitution is where bash's parser stops counting the substitution, and the failure is a
# syntax error 200 lines later, not at the line that caused it)
yn()     { "$@" >/dev/null 2>&1; echo $?; }
eq()     { [ "$1" = "$2" ]; }
has()    { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
hasany() { local hay="$1" p; shift; for p in "$@"; do has "$hay" "$p" && return 0; done; return 1; }
hasall() { local hay="$1" p; shift; for p in "$@"; do has "$hay" "$p" || return 1; done; return 0; }
allof()  { local rc=0; while [ $# -gt 0 ]; do [ "$1" = 0 ] || rc=1; shift; done; echo $rc; }

[ -f "$LOOP" ] || { echo "❌ missing $LOOP"; exit 2; }

# ── extraction: the shipped code, not a copy ──────────────────────────────────────────────────────
FNS="$T/fns.sh"
{
  grep -E '^is_num\(\) \{'   "$LOOP"
  grep -E '^is_limit\(\) \{' "$LOOP"
  sed -n '/^ci_queue_depth() {/,/^}/p'        "$LOOP"
  sed -n '/^ci_lane_ceiling() {/,/^}/p'       "$LOOP"
  sed -n '/^ci_congestion_reason() {/,/^}/p'  "$LOOP"
  sed -n '/^ci_cycle_gate() {/,/^}/p'         "$LOOP"
  # the skip line: the shipped formatter + the record readers it depends on
  sed -n '/^refresh_record_snapshot() {/,/^}/p' "$LOOP"
  sed -n '/^refresh_record_field() {/,/^}/p'    "$LOOP"
  sed -n '/^refresh_cause_brief() {/,/^}/p'     "$LOOP"
  sed -n '/^dispatch_gate_line() {/,/^}/p'      "$LOOP"
  sed -n '/^mp_reason() {/,/^}/p'               "$LOOP"
} > "$FNS"
EXTRACT_RC=0
for _f in is_num is_limit ci_queue_depth ci_lane_ceiling ci_congestion_reason ci_cycle_gate \
          refresh_record_snapshot dispatch_gate_line mp_reason; do
  hasin=0; grep -q "^$_f() {" "$FNS" && hasin=1
  [ "$hasin" = 1 ] || { printf '      not extracted: %s\n' "$_f"; EXTRACT_RC=1; }
done
ck "P0 (setup) the CI-queue functions and the skip-line formatter extract from the shipped orch-loop.sh" "$EXTRACT_RC" P0
[ "$EXTRACT_RC" -eq 0 ] || { echo "❌ nothing can be graded without them"; exit 2; }

# the shipped [cap] line and the shipped gate chain — extracted, then DRIVEN below
grep -E '^  echo "\[cap\] load=' "$LOOP" > "$T/capline.sh"
sed -n '/# \[ci-line:begin\]/,/# \[ci-line:end\]/p' "$LOOP" | sed '1d;$d' > "$T/ciline.sh"
sed -n '/^  GATE_WHY="\$(mp_reason/,/^  fi$/p' "$LOOP" > "$T/gate.sh"
ck "P0 (setup) the shipped [cap] line is extractable" "$(yn test -s "$T/capline.sh")" P0
ck "P0 (setup) the shipped gate chain is extractable" "$(yn test -s "$T/gate.sh")" P0
ck "P0 (setup) the shipped [ci] CONGESTED line is extractable" "$(yn has "$(cat "$T/ciline.sh" 2>/dev/null)" '[ci] CONGESTED')" P0

# ── the stub gh: REST only, and it RECORDS what it was asked ─────────────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Records every call, answers the two status counts from the environment, can fail on demand.
printf 'gh %s\n' "$*" >> "${GHSPY:?}"
case "$*" in
  *status=queued*)
    [ "${GH_FAIL:-}" = "queued" ] && { printf 'gh: HTTP 502 Bad Gateway\n' >&2; exit 1; }
    if [ "${GH_BODY:-}" = "notfound" ]; then
      printf '%s\n' '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/actions"}'
      exit 0
    fi
    printf '%s\n' "${GH_Q:-0}" ;;
  *status=in_progress*)
    [ "${GH_FAIL:-}" = "in_progress" ] && { printf 'gh: HTTP 502 Bad Gateway\n' >&2; exit 1; }
    printf '%s\n' "${GH_P:-0}" ;;
  *) printf 'stub gh: UNMODELLED call: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

# ── the driver: run the SHIPPED decision for one (max_lanes, queued, in_progress) fixture ────────
drive() { # <max_lanes> <gh_queued> <gh_in_progress> <lanes_in_use> [KEY=VALUE …environment extras]
  local maxl="$1" q="$2" p="$3" lanes="$4"; shift 4
  : > "$T/spy"
  mkdir -p "$T/O/state"
  # the [dispatch] formatter needs a SUCCESSFUL refresh record AND a queued candidate for its
  # `skipped (` arm — otherwise it would print `BLOCKED`/`nothing to defer` and grade the wrong line.
  printf 'result=ok\nat=%s\nqueued=2\nhanded=41\n' "$(date +%s)" > "$T/O/state/refresh-last"
  printf '41\n42\n' > "$T/O/candidates.txt"
  (
    # ⛔ `set -u`, THE SAME AS THE DAEMON (`orch-loop.sh` runs under `set -u`). Under `set +u` an
    # unbound `${CI_QUEUE_MAX}` expands to EMPTY silently, so a fixture that "passes" would not notice
    # the change that aborts the live loop on its first cycle.
    set -u
    # ⛔ THE SUITE'S OWN KNOBS ARE RESET, not inherited: the README tells operators to set these in the
    # harness environment, which is the same shell that runs the suites — an inherited CI_QUEUE_MAX=200
    # would silently redden the above-bound arms (and an inherited 10 would green them wrong). Only a
    # `KEY=VALUE` extra passed to `drive` may move them.
    unset CI_QUEUE_MAX CI_QUEUE_LANES
    MAX_LANES="$maxl"; OR=daniel-ospina/tortoise; O="$T/O"; LOG="$T/log"; REPO=/nonexistent
    GHSPY="$T/spy"; GH_Q="$q"; GH_P="$p"
    export GHSPY GH_Q GH_P
    L=7; MAX_LOAD=100; LANES="$lanes"; WORKERS=0; MR=4; MF=3; OPEN_N=29; UPN=0; UPN_WORK=0
    SEL_TOTAL=29; OWN_N=0; SEL_PARKED=0; FIRST_PR=12
    MEMAVAIL_MB=9000; MIN_MEM_FREE_MB=512; SWFREE=9000; MIN_SWAP_FREE=600; SWTOTAL=2048
    MEM_UNKNOWN=0; CAP_STATE=unavailable; CAP_PLACE=""; CAP_BOUND=""
    LAND_AGE=3; MERGE_PRIORITY_AT=25; REFRESH_STALE_LOCK_MIN=20; RUNNING_STALE_MIN=20
    PRDISP_ACTS=""; PRDISP_WAITS=""; PRDISP_REC=unknown
    for _kv in "$@"; do export "${_kv?}"; done
    # shellcheck source=/dev/null
    . "$FNS"
    # merge-priority is isolated EXCEPT where its precedence is the point (USE_REAL_MP=1, T10).
    [ "${USE_REAL_MP:-0}" = "1" ] || mp_reason() { :; }
    : > "$LOG"
    ci_cycle_gate
    GATE_WHY=""; eval "$(cat "$T/gate.sh")"
    rm -f "$LOG"; eval "$(cat "$T/capline.sh")"
    CILINE="$(eval "$(cat "$T/ciline.sh")"; cat "$LOG" 2>/dev/null | grep '^\[ci\] ' | head -1)"
    CAPLINE="$(grep '^\[cap\] ' "$LOG" 2>/dev/null | head -1)"
    # ⛔ THE CONFIGURED CEILING IS PART OF THE READING: `MAX_LANES` must come out UNCHANGED (the loop
    # is ONE process, so a write-back would outlive the congestion), and it is only observable here.
    MAXLANES_AFTER="$MAX_LANES"
    SKIPLINE="$(dispatch_gate_line "${GATE_WHY:-}" "$LANES" "$WORKERS" "none" 2>/dev/null)"
    { printf '%s\n' "$LANE_CEILING"; printf '%s\n' "$CI_TOK"; printf '%s\n' "${CI_GATE_WHY:-}"
      printf '%s\n' "${GATE_WHY:-}"; printf '%s\n' "$CAPLINE"; printf '%s\n' "$SKIPLINE"
      printf '%s\n' "$MAXLANES_AFTER"; printf '%s\n' "${CILINE:-}"; } > "$T/out"
  ) 2>"$T/err"
  cp "$T/spy" "$T/spy.saved"
  ERR="$(cat "$T/err" 2>/dev/null)"
}
out()      { sed -n "${1}p" "$T/out"; }
CEILING()  { out 1; }
TOK()      { out 2; }
WHY()      { out 3; }
GATEWHY()  { out 4; }
CAPLINE()  { out 5; }
SKIPLINE() { out 6; }
MAXL()     { out 7; }
CILINE()   { out 8; }
countof()  { grep -Ec "$1" "$2" 2>/dev/null | head -1; }
err_clean() { [ -z "${ERR:-}" ]; }

echo
echo "── T1: queued BELOW the bound — ceiling unchanged, depth still printed ─────────────────────"
drive 25 10 2 3
ck "T1a the ceiling is the configured MAX_LANES (25)" "$(yn eq "$(CEILING)" 25)" T1
ck "T1b the [cap] token is queued/in_progress (10/2)" "$(yn eq "$(TOK)" 10/2)" T1
ck "T1c no ci-congestion reason (the ceiling was not reduced)" "$(yn test -z "$(WHY)")" T1
ck "T1d the gate chain stays OPEN (3 lanes < ceiling 25)" "$(yn test -z "$(GATEWHY)")" T1
ck "T1e the [cap] line SHOWS the depth (ci=10/2) even when nothing is throttled" \
   "$(yn has "$(CAPLINE)" 'ci=10/2')" T1
ck "T1f the [cap] line shows the ceiling actually used (lanes=3/25)" \
   "$(yn has "$(CAPLINE)" 'lanes=3/25 ')" T1
ck "T1g the driver ran with clean stderr (no unbound variable, no stub noise)" "$(yn err_clean)" T1

echo
echo "── T2: queued ABOVE the bound — ceiling reduced, skip line NAMES the gate + numbers ────────"
drive 25 140 1 9
printf '     [cap]      %s\n' "$(CAPLINE)"
printf '     [dispatch] %s\n' "$(SKIPLINE)"
ck "T2a the ceiling is reduced to CI_QUEUE_LANES (25 -> 3)" "$(yn eq "$(CEILING)" 3)" T2
ck "T2b the reason names the gate: ci-congestion" \
   "$(yn has "$(WHY)" 'ci-congestion (')" T2
ck "T2c the reason carries the measured queue, the bound and both ceilings" \
   "$(yn eq "$(WHY)" 'ci-congestion (queued=140 > 60 → lanes 25→3)')" T2
ck "T2d the SKIP line names the gate (the [dispatch] skipped formatter prints it verbatim)" \
   "$(yn has "$(SKIPLINE)" '[dispatch] skipped (ci-congestion (queued=140 > 60 → lanes 25→3))')" T2
ck "T2e the skip line still carries lanes/workers (unchanged shape)" \
   "$(yn has "$(SKIPLINE)" 'lanes=9 workers=0')" T2
ck "T2f the [cap] line prints the REDUCED ceiling and the depth together" \
   "$(yn hasall "$(CAPLINE)" 'lanes=9/3 ' 'ci=140/1')" T2
ck "T2g the gate chain reports ci-congestion, not the generic lanes arm" \
   "$(yn eq "$(GATEWHY)" 'ci-congestion (queued=140 > 60 → lanes 25→3)')" T2
ck "T2h the driver ran with clean stderr (under set -u, like the daemon)" "$(yn err_clean)" T2
ck "T2i the CONFIGURED max lanes is untouched (still 25) — the throttle is per-cycle, never a write-back" \
   "$(yn eq "$(MAXL)" 25)" T2
ck "T2j the [ci] CONGESTED line names the numbers even when another gate wins the skip line" \
   "$(yn hasall "$(CILINE)" '[ci] CONGESTED ci-congestion (queued=140 > 60 → lanes 25→3)' 'in_progress=1')" T2

echo
echo "── T3: the reduced ceiling NEVER starves the fleet ─────────────────────────────────────────"
drive 25 140 1 9 CI_QUEUE_LANES=0
ck "T3a CI_QUEUE_LANES=0 is floored to 1 (a ceiling of 0 can drain nothing)" \
   "$(yn eq "$(CEILING)" 1)" T3
ck "T3b the floor is what the reason reports (lanes 25→1)" \
   "$(yn eq "$(WHY)" 'ci-congestion (queued=140 > 60 → lanes 25→1)')" T3
drive 1 140 1 9 CI_QUEUE_LANES=8
ck "T3c a ceiling already BELOW the reduced value is never reduced further (1 stays 1)" \
   "$(yn eq "$(CEILING)" 1)" T3
drive 0 140 1 0
ck "T3d a deliberate MAX_LANES=0 is never RAISED to 1 by the throttle" "$(yn eq "$(CEILING)" 0)" T3
ck "T3e …and with no reduction made, the gate does not claim one" "$(yn test -z "$(WHY)")" T3

echo
echo "── T4: an UNREADABLE queue falls back to the CURRENT behaviour and SAYS SO ────────────────"
drive 25 0 0 9 GH_FAIL=queued
ck "T4a the token says UNREADABLE (fail-open must not mean fail-blind)" \
   "$(yn eq "$(TOK)" UNREADABLE)" T4
ck "T4b the ceiling is UNCHANGED (25) — an unreadable instrument never throttles the fleet" \
   "$(yn eq "$(CEILING)" 25)" T4
ck "T4c no ci-congestion reason is produced" "$(yn test -z "$(WHY)")" T4
ck "T4d the gate chain stays OPEN, exactly as before this change" \
   "$(yn test -z "$(GATEWHY)")" T4
ck "T4e the [cap] line prints ci=UNREADABLE" "$(yn has "$(CAPLINE)" 'ci=UNREADABLE')" T4
drive 25 0 0 9 GH_FAIL=in_progress
ck "T4f a half-read queue (in_progress failing) is UNREADABLE, not a partial reading" \
   "$(yn allof "$(yn eq "$(TOK)" UNREADABLE)" "$(yn eq "$(CEILING)" 25)")" T4
drive 25 0 0 9 GH_BODY=notfound
ck "T4g a 200 whose body is not a number (a 404 body) reads UNREADABLE, never 0" \
   "$(yn allof "$(yn eq "$(TOK)" UNREADABLE)" "$(yn eq "$(CEILING)" 25)")" T4
ck "T4h …so it never takes the '0 queued ⇒ under the bound' shortcut" \
   "$(yn has "$(CAPLINE)" 'ci=UNREADABLE')" T4

echo
echo "── T5: the bound is READ, in both directions (not a hardcoded 60) ─────────────────────────"
drive 25 60 1 9
ck "T5a queued == the bound is NOT over it (60 > 60 is false)" "$(yn eq "$(CEILING)" 25)" T5
drive 25 61 1 9
ck "T5b one over the bound IS over it (61 -> reduced)" "$(yn eq "$(CEILING)" 3)" T5
drive 25 140 1 9 CI_QUEUE_MAX=200
ck "T5c a raised CI_QUEUE_MAX (200) keeps 140 harmless — the value is read, not assumed" \
   "$(yn allof "$(yn eq "$(CEILING)" 25)" "$(yn test -z "$(WHY)")")" T5
drive 25 140 1 9 CI_QUEUE_MAX=10
ck "T5d a lowered CI_QUEUE_MAX (10) throttles, and the reason reports THAT bound" \
   "$(yn eq "$(WHY)" 'ci-congestion (queued=140 > 10 → lanes 25→3)')" T5
drive 25 140 1 9 CI_QUEUE_LANES=7
ck "T5e a non-default CI_QUEUE_LANES (7) is the ceiling used" "$(yn eq "$(CEILING)" 7)" T5

echo
echo "── T6: the read is REST, is exactly two calls, carries the total_count jq ─────────────────"
drive 25 140 1 9
ck "T6a exactly ONE queued-runs read and ONE in_progress read, and nothing else" \
   "$(yn allof "$(yn eq "$(countof 'actions/runs?status=queued' "$T/spy.saved")" 1)" \
            "$(yn eq "$(countof 'actions/runs?status=in_progress' "$T/spy.saved")" 1)" \
            "$(yn eq "$(countof '.' "$T/spy.saved")" 2)")" T6
ck "T6b no GraphQL call is made (the congested box is the one whose GraphQL budget is gone)" \
   "$(yn eq "$(countof 'graphql' "$T/spy.saved")" 0)" T6
ck "T6c both reads are 'gh api repos/<owner>/<repo>/actions/runs?status=… --jq .total_count'" \
   "$(yn eq "$(countof 'gh api repos/daniel-ospina/tortoise/actions/runs[?]status=.*per_page=1 --jq [.]total_count' "$T/spy.saved")" 2)" T6

echo
echo "── T7: the [cap] line stays parseable (no machine reader — the SHAPE is the contract) ─────"
CAP="$(CAPLINE)"
KEYS="$(printf '%s\n' "$CAP" | sed -e 's/^\[cap\] //' -e 's/ /\n/g' | sed -e 's/=.*//' | tr '\n' ' ' | sed 's/ $//')"
EXPECT="load lanes mem_avail swap_free open unowned last_land review_slots fix_slots ci"
ck "T7a the line starts with '[cap] ' and is a SINGLE line" \
   "$(yn allof "$(yn has "$CAP" '[cap] ')" "$(yn eq "$(printf '%s\n' "$CAP" | grep -c .)" 1)")" T7
ck "T7b every pre-existing key survives, in order, with ci= appended (got: $KEYS)" \
   "$(yn eq "$KEYS" "$EXPECT")" T7
ck "T7c lanes= stays a numeric N/M pair (now N/<effective ceiling>)" \
   "$(yn eq "$(printf '%s\n' "$CAP" | grep -Ec '(^| )lanes=[0-9]+/[0-9]+( |$)' | head -1)" 1)" T7
ck "T7d no field has an empty value (a '?' or a number is a reading; empty is a broken line)" \
   "$(yn eq "$(printf '%s\n' "$CAP" | sed -e 's/^\[cap\] //' -e 's/ /\n/g' | grep -Ec '=$' | head -1)" 0)" T7

echo
echo "── T8: the reduced ceiling CAPS new work — it never becomes a STOP ─────────────────────"
drive 25 140 1 9
ck "T8a the reason names ci-congestion and NO other gate" \
   "$(yn allof "$(yn has "$(WHY)" 'ci-congestion (')" \
            "$(yn hasany "$(WHY)" 'merge-priority' 'load=' 'swap_free' 'mem_avail' 'capacity-placement' | sed 's/^0$/1/;s/^1$/0/')")" T8
drive 25 140 1 2
ck "T8b lanes=2 UNDER the reduced ceiling (3) leaves the gate OPEN — a cap, not a stop" \
   "$(yn test -z "$(GATEWHY)")" T8
ck "T8c …and that cycle still reports the reduced ceiling it may use (lanes=2/3)" \
   "$(yn has "$(CAPLINE)" 'lanes=2/3 ')" T8
ck "T8d …and still SAYS CI is congested (the reading is not conditional on blocking)" \
   "$(yn has "$(CILINE)" 'ci-congestion (queued=140 > 60 → lanes 25→3)')" T8
drive 25 140 1 3
ck "T8e lanes=3 AT the reduced ceiling is what closes the gate, naming ci-congestion" \
   "$(yn eq "$(GATEWHY)" 'ci-congestion (queued=140 > 60 → lanes 25→3)')" T8
drive 25 140 1 0
ck "T8f zero lanes in use still yields the reason (the gate is about the queue, not the lanes)" \
   "$(yn eq "$(WHY)" 'ci-congestion (queued=140 > 60 → lanes 25→3)')" T8
ck "T8g the queue is read even when nothing could be dispatched (the [cap] line explains a stall)" \
   "$(yn has "$(CAPLINE)" 'ci=140/1')" T8
ck "T8h both reads still happen on that cycle" "$(yn eq "$(countof '.' "$T/spy.saved")" 2)" T8

echo
echo "── T10: PRECEDENCE — merge-priority wins the skip line, the congestion is STILL named ──────"
# ⛔ THE INTERACTION THE STUB HIDES. `mp_reason` is threshold-free (ONE un-owned PR closes the issue
# path, owner ruling 2026-10-18) and a congested box ALWAYS has un-owned PRs — they are un-owned
# because CI cannot verify them. So the skip line names merge-priority in exactly the state this gate
# exists for. That is correct precedence, but it must not make the congestion INVISIBLE: the [ci]
# line carries it, and this arm drives the REAL mp_reason to prove both halves.
drive 25 140 1 9 USE_REAL_MP=1 UPN_WORK=29
printf '     [dispatch] %s\n' "$(SKIPLINE)"
printf '     [ci]       %s\n' "$(CILINE)"
ck "T10a the skip line names merge-priority (the owner's ruling still wins the reason)" \
   "$(yn has "$(SKIPLINE)" 'merge-priority (29 un-owned of')" T10
ck "T10b the ceiling was still reduced to 3" "$(yn eq "$(CEILING)" 3)" T10
ck "T10c …and the [ci] line names the queue, the bound and the ceiling change" \
   "$(yn hasall "$(CILINE)" 'ci-congestion (queued=140 > 60 → lanes 25→3)' 'in_progress=1')" T10
ck "T10d the [cap] line carries the depth beside the un-owned count (both readings, one line)" \
   "$(yn hasall "$(CAPLINE)" 'unowned=' 'ci=140/1')" T10
ck "T10e the configured max lanes is untouched here too" "$(yn eq "$(MAXL)" 25)" T10

echo
echo "──────────────────────────────────────────────────────────────────────────────"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"

# ── T9: NON-VACUITY (always on) ────────────────────────────────────────────────────────────────
# The throttle is rewritten to a no-op at its MUT-ANCHOR in a COPY of the shipped loop, and the
# above-bound arm (T2) is REQUIRED to fail. Without this, every T2 assertion could be green on a
# function that never bound the ceiling — the suite would be grading its own fixtures. A missing
# ANCHOR is therefore a FAILURE, not a skip: an unmutatable gate is an unproven one.
mutate_to() { # <out-file>
  local anchor='MUT-ANCHOR:ci-ceiling'
  grep -q "$anchor" "$LOOP" || return 1
  MUT_ANCHOR="$anchor" awk '
    index($0, ENVIRON["MUT_ANCHOR"]) { print "  printf \"%s\\n\" \"$max\"; return 0"; next }
    { print }
  ' "$LOOP" > "$1" || return 1
  bash -n "$1" || return 1
  grep -q 'printf "%s\\n" "$max"; return 0' "$1"
}

if [ "${CI_CAP_MUTANT_RUN:-0}" = "1" ]; then
  # This IS the mutant run: the throttle is already removed and there is nothing further to prove.
  # (The child must NOT build its own mutant, or the proof recurses forever.)
  :
else
  MUT="$T/mutant-orch-loop.sh"
  if mutate_to "$MUT"; then
    ok "T9a the throttle was DISABLED in a copy of the shipped loop (anchor found, copy parses)"
    # `CI_CAP_MUTANT_RUN=1` is what stops the recursion — a reader, not a decoration.
    env CI_CAP_MUTANT_RUN=1 LOOP="$MUT" bash "${BASH_SOURCE[0]}" > "$T/mutant.out" 2>&1
    MRC=$?
    if [ "$MRC" -ne 0 ] && grep -q '❌ \[T2\]' "$T/mutant.out"; then
      ok "T9b [RED PROOF] with the throttle removed the above-bound arm (T2) FAILS — the gate is load-bearing"
      printf '     mutant: %s red assertion(s); first: %s\n' \
        "$(grep -c '❌' "$T/mutant.out" | tr -d ' ')" \
        "$(grep -m1 '❌' "$T/mutant.out" | sed 's/^ *//')"
    else
      bad "T9b with the throttle removed the above-bound arm STAYED GREEN (rc=$MRC) — the suite grades its own fixtures, not the gate" T9
      grep '❌' "$T/mutant.out" | head -5
    fi
  else
    bad "T9a the 'MUT-ANCHOR:ci-ceiling' anchor is missing from orch-loop.sh — the throttle cannot be proven load-bearing" T9
  fi
  echo
  printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
fi

[ "$FAIL" -eq 0 ] || { printf '\n  failed: %s\n' "${FAILED_IDS# }"; exit 1; }
exit 0
