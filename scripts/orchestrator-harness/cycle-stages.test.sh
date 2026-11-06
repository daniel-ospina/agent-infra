#!/usr/bin/env bash
# cycle-stages.test.sh — the per-stage wall-clock attribution in `state/cycles`.
#
# WHAT WAS BROKEN (the measurements this suite exists to keep impossible to regress).
# A cycle record carried ONE number about time — `end - start` — plus the `interval=` it was designed
# against. Measured cycles of 2.2, 17.5, 131, 145 and 161 minutes against `interval=240` proved that
# number does NOT track work: the 161-minute cycle spawned ZERO workers and a 2.2-minute cycle also
# spawned zero, while a 17.5-minute cycle spawned six. So the time was going somewhere STRUCTURAL and
# the record could not say where, because `CYC` bounds only the nap and the cycle BODY is unbounded.
# `stages=` is the field that makes the total ATTRIBUTABLE. This suite is what stops it decaying back
# into a number nobody can act on:
#
#   §0  both shipped modules are sourced and every function this suite calls EXISTS (see the note
#       below — without it every arm here can go green on a missing command)
#   §1  the grammar: a well-formed value validates, a malformed one does not
#   §2  NON-VACUITY — the field blames THE stage that was slow, and the blame MOVES when the slow
#       stage moves. A field that spread evenly, or always blamed the same stage, would pass a naive
#       "it has numbers in it" check; these arms are the ones that would catch it.
#   §3  `ns` vs `0` — a registered stage that never sampled is `ns`, NEVER a measured-looking 0
#   §4  ONE SOURCE — the stage set is the registry, so a stage added there appears in the record with
#       no second edit, and a stage can never vanish from the record while still being in the registry
#   §5  the TILED stages tile: their sum is the body's wall time, so no time escapes the instrument
#   §6  FORK-FREE — the clock runs BEFORE `fork_gate`, on the path where one `$( )` kills the
#       controller (agent-infra#2293). Asserted structurally against the shipped block.
#   §7  BACKWARDS COMPATIBILITY — a record with NO `stages=` field still parses for EVERY reader
#   §8  the record stays ONE space-separated `k=v` line: the new field cannot break the grammar that
#       the other twenty fields share
#   §9  THE THREE DEFECTS A FRESH-CONTEXT REVIEW FOUND, each armed so it cannot come back: an overlay
#       written in the sweep's PIPELINE SUBSHELL must still reach the record — including the LAST
#       row's interval, which no subsequent settle would ever close — `prev_wait` must be ONE gap
#       rather than a lifetime sum, and every declared cascade level must have a real call site
#       instead of a fabricated measured zero. §2–§3 could not catch these: they drive the clock in
#       the MAIN shell, never through a subshell boundary and never across two cycles.
#
# ⛔ THE VACUITY TRAP THIS FILE WAS BORN WITH, AND HOW IT IS CLOSED (driven, not guessed: the first
# draft of this suite sourced only the extracted clock and never `cycle-record.sh`, so
# `cycle_stages_valid` was `command not found` — and every REFUSAL arm, written
# `cmd && echo 1 || echo 0`, then scored ✅ because a missing command takes the `||` branch. Six
# grammar arms were green *because the validator did not exist*.) Two structural defences, both in
# §0: every function this suite calls is asserted to EXIST before any arm runs, and a missing one
# aborts the suite (exit 2) instead of grading. An arm may never be able to pass on an absence.
#
# HOW THESE ARE WRITTEN. §1/§7/§8 drive the SHIPPED `cycle-record.sh`. §2–§6 extract the SHIPPED
# stage-clock block from `orch-loop.sh` between its `[stageclock]` markers and drive it — never a
# re-implementation, which would pass on the broken tree too. Real sleeps, not a stubbed clock, so the
# arms grade the clock that actually ships.
#
# ⛔ NO `… | grep -q …` ANYWHERE (scripts/check-no-sigpipe-grep.sh): a quiet grep closes the pipe, the
# writer takes SIGPIPE, and under `pipefail` the pipeline reports the WRITER's status — a false PASS.
# Pipelines here are captured into a variable or fed by a here-string, never terminated by a quiet grep.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
qF() { grep -qF -- "$1" <<<"${2:-}"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cycle-stages.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
CR="$HERE/cycle-record.sh"; ORCH="$HERE/orch-loop.sh"; HARNESS_BIN="$ROOT/bin/harness"
for f in "$CR" "$ORCH"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite grades the shipped files, so it cannot run"; exit 2; }
done
echo "==> cycle-stages self-test ($HERE)"

# ── §0 sources, and the existence gate that stops an absence scoring as a pass ────────────────
echo
echo "── §0 both shipped modules are sourced, and every function this suite calls exists ──"
sed -n '/# \[stageclock:begin\]/,/# \[stageclock:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/clock.sh"
if [ -s "$TMP/clock.sh" ] && qF 'STG_REGISTRY_TILED=' "$(cat "$TMP/clock.sh")"; then
  ck "the stage-clock block is extracted from the shipped loop" 0
else
  ck "the stage-clock block is extracted from the shipped loop" 1
  echo "❌ extraction failed — aborting (every later arm would grade an empty file)"; exit 2
fi
# shellcheck source=/dev/null
. "$CR"                    # cycle_stage_get / cycle_stages_valid / cycle_verdict / cycle_history
# shellcheck source=/dev/null
. "$TMP/clock.sh"          # the shipped stage clock
_missingfn=""
for _fn in cycle_stages_valid cycle_stage_get cycle_verdict cycle_history cycle_record_write \
           stg_cycle_reset stg_mark stg_lvl_start stg_lvl_settle stg_nap_mark stg_field \
           stg_now_us stg_now_us_vars stg_add stg_lvl_accum stg_lvl_fold; do
  declare -f "$_fn" >/dev/null 2>&1 || _missingfn="$_missingfn $_fn"
done
ck "every function under test is defined by the shipped modules${_missingfn:+ (missing:$_missingfn)}" \
   "$([ -z "$_missingfn" ] && echo 0 || echo 1)"
if [ -n "$_missingfn" ]; then
  echo "❌ a function under test does not exist — aborting rather than grading absences as passes"
  exit 2
fi

# ── §1 the grammar ──────────────────────────────────────────────────────────────────────────────
echo
echo "── §1 the stages= grammar: name:secs, name:ns, one comma-separated space-free list ──"
# ⛔ EVERY ARM BELOW IS WRITTEN `if …; then 0; else 1; fi`, NOT `cmd && echo 0 || echo 1`.
# The `&&`/`||` form cannot distinguish "the check returned false" from "the check does not exist",
# and this suite has already been bitten by exactly that (~§0). A verdict that can be produced by an
# error is not a verdict.
_accepts() { if cycle_stages_valid "$1"; then echo 0; else echo 1; fi; }
_refuses() { if cycle_stages_valid "$1"; then echo 1; else echo 0; fi; }
ck "a canonical value validates" "$(_accepts 'boot:3,sweep:960,l1_main:ns,prev_wait:241')"
ck "  …and a single pair validates (no trailing comma required)" "$(_accepts 'boot:0')"
ck "a zero is legal and is NOT the same token as ns" \
   "$(if cycle_stages_valid 'boot:0' && cycle_stages_valid 'boot:ns'; then echo 0; else echo 1; fi)"
ck "a TRAILING comma is refused"                     "$(_refuses 'boot:3,')"
ck "a DOUBLE comma is refused (an empty element is not a stage)" "$(_refuses 'boot:3,,disk:1')"
ck "a missing ':' separator is refused"              "$(_refuses 'boot3,disk:1')"
ck "a NEGATIVE duration is refused"                  "$(_refuses 'boot:-1')"
ck "a FRACTIONAL duration is refused (whole seconds by contract)" "$(_refuses 'boot:1.5')"
ck "a SPACE in the value is refused — the writer would rewrite it to '_' and the field would be junk" \
   "$(_refuses 'boot:3, disk:1')"
ck "an EMPTY value is refused (absent is not a valid empty field)" "$(_refuses '')"
ck "an unknown verb is refused, so a typo cannot validate by accident" "$(_refuses 'boot:3,junk')"

# ── §2 NON-VACUITY: the blame follows the slow stage ───────────────────────────────────────────
echo
echo "── §2 NON-VACUITY: the stage that was slow is the stage the record blames ──"
# drive <slow-stage> — a synthetic cycle-shaped drive over the SHIPPED clock.
# `slow` names the stage that receives a ~2.2 s stall immediately BEFORE its own closing mark, so the
# stall lands inside that stage's interval by construction and nowhere else. The cascade overlays are
# driven INSIDE the sweep interval, which is the containment a real cycle has (`sum(l1..l4) <= sweep`)
# and is what makes §5's relation meaningful.
drive() { # drive <slow-stage>
  local slow="${1:-none}" n
  stg_cycle_reset
  for n in boot disk reap refresh authority claims caches; do
    [ "$slow" = "$n" ] && sleep 2.2
    stg_mark "$n"
  done
  for n in l2_merge l3_fix l4_review; do
    stg_lvl_start "$n"
    [ "$slow" = "$n" ] && sleep 2.2
  done
  stg_lvl_settle
  [ "$slow" = "sweep" ] && sleep 2.2
  stg_mark sweep
  for n in gate l5_issue record; do
    [ "$slow" = "$n" ] && sleep 2.2
    stg_mark "$n"
  done
  stg_field STG_FIELD
  printf '%s' "$STG_FIELD"
}
# get <field-or-record> <stage> — the stage's value, or the literal `ABSENT` when it is not named.
# ⛔ IT ACCEPTS A BARE `stages=` VALUE **OR** A WHOLE RECORD, and that tolerance is load-bearing: the
# first draft always prefixed `stages=`, so handing it a full record produced `stages=start=…` and the
# reader matched the LEADING token — reporting a stage as ABSENT from a record that plainly carried
# it. A helper whose mistake makes a field look MISSING is the failure this whole change exists to end.
get() {
  local _g_rec="${1:-}" _g_v
  case "$_g_rec" in *"${CR_STAGES_FIELD}="*) ;; *) _g_rec="${CR_STAGES_FIELD}=${_g_rec}" ;; esac
  if _g_v="$(cycle_stage_get "$_g_rec" "$2")"; then printf '%s' "$_g_v"; else printf 'ABSENT'; fi
}
# atleast <value> <n> — numeric >=, refusing ABSENT/ns (a non-answer must never satisfy a bound).
atleast() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge "$2" ]; }
eqv() { [ "${1:-}" = "${2:-}" ]; }
# ok <0|1> — turn a helper's status into the `ck` argument, without the && / || ambiguity.
ok() { if [ "$1" -eq 0 ]; then echo 0; else echo 1; fi; }

F_BOOT="$(drive boot)"
_b_boot="$(get "$F_BOOT" boot)";  _b_disk="$(get "$F_BOOT" disk)"
_b_late="$(get "$F_BOOT" sweep),$(get "$F_BOOT" gate),$(get "$F_BOOT" l5_issue),$(get "$F_BOOT" record)"
_b_lvl="$(get "$F_BOOT" l2_merge),$(get "$F_BOOT" l3_fix),$(get "$F_BOOT" l4_review)"
ck "the emitted field is well formed and complete" \
   "$(if cycle_stages_valid "$F_BOOT"; then echo 0; else echo 1; fi)"
ck "a 2.2 s stall in BOOT is attributed to boot (boot >= 2), got '$_b_boot'" \
   "$(atleast "$_b_boot" 2; ok $?)"
ck "  …and NOT to the stage that ran immediately after it (disk == 0), got '$_b_disk'" \
   "$(eqv "$_b_disk" 0; ok $?)"
ck "  …nor to any LATER tiled stage (sweep/gate/l5_issue/record), got '$_b_late'" \
   "$(eqv "$_b_late" '0,0,0,0'; ok $?)"
ck "  …nor to any cascade level (l2/l3/l4) — the stall was not in an arm, got '$_b_lvl'" \
   "$(eqv "$_b_lvl" '0,0,0'; ok $?)"

# ⛔ THE ARMS THAT MAKE THE FIRST ONES MEAN SOMETHING. If the instrument simply blamed `boot` for
# everything (a hard-coded label, a sign error, or a field that reports the TOTAL under one key), the
# arms above would still pass. Moving the stall must move the blame.
F_SWEEP="$(drive sweep)"
_s_sweep="$(get "$F_SWEEP" sweep)"; _s_boot="$(get "$F_SWEEP" boot)"
ck "THE BLAME MOVES: a 2.2 s stall in SWEEP lands on sweep (got '$_s_sweep')" \
   "$(atleast "$_s_sweep" 2; ok $?)"
ck "  …and boot drops back to 0 in that drive (got '$_s_boot')" \
   "$(eqv "$_s_boot" 0; ok $?)"

F_L4="$(drive l4_review)"
_l_l4="$(get "$F_L4" l4_review)"; _l_23="$(get "$F_L4" l2_merge),$(get "$F_L4" l3_fix)"
_l_boot="$(get "$F_L4" boot)"; _l_other="$(get "$F_L4" refresh),$(get "$F_L4" gate)"
_l_sweep="$(get "$F_L4" sweep)"
ck "THE BLAME MOVES AGAIN: a stall in the CASCADE LEVEL l4_review lands on l4_review (got '$_l_l4')" \
   "$(atleast "$_l_l4" 2; ok $?)"
ck "  …and NOT on l2_merge or l3_fix, the levels either side of it in the same sweep (got '$_l_23')" \
   "$(eqv "$_l_23" '0,0'; ok $?)"
ck "  …and not on the tiled stages outside the sweep (boot/refresh/gate), got '$_l_boot / $_l_other'" \
   "$(if eqv "$_l_boot" 0 && eqv "$_l_other" '0,0'; then echo 0; else echo 1; fi)"
# ⛔ NOT "EVENLY SPREAD": among the four cascade levels, exactly ONE may hold the stall. This is the
# assertion that fails if the field ever starts distributing time (e.g. crediting the whole sweep to
# every level, which would read as a plausible pyramid fill and explain nothing).
_holders=0
for _s in l1_main l2_merge l3_fix l4_review; do
  _v="$(get "$F_L4" "$_s")"
  if atleast "$_v" 2; then _holders=$((_holders+1)); fi
done
ck "exactly ONE cascade level holds the stall (got $_holders)" \
   "$(if [ "$_holders" -eq 1 ]; then echo 0; else echo 1; fi)"

# ── §3 ns is not 0 ─────────────────────────────────────────────────────────────────────────────
echo
echo "── §3 'ns' (never sampled) is a different reading from '0' (measured, cost nothing) ──"
_l1="$(get "$F_BOOT" l1_main)"
ck "a REGISTERED but not-yet-implemented stage reads ns, never a measured-looking 0 (got '$_l1')" \
   "$(eqv "$_l1" ns; ok $?)"
ck "a stage that WAS sampled and cost nothing reads 0 — the two are distinguishable in one field" \
   "$(qF 'disk:0' "$F_BOOT"; ok $?)"
ck "cycle_stage_get returns the literal ns (a reader can branch on it, not on 'missing')" \
   "$(if cycle_stage_get "stages=$F_BOOT" l1_main >/dev/null 2>&1; then echo 0; else echo 1; fi)"

# ── §4 ONE SOURCE: the registry is the stage set ───────────────────────────────────────────────
echo
echo "── §4 ONE SOURCE — the registry is the stage set, so a stage cannot silently vanish ──"
_missing=""
for _s in $STG_REGISTRY; do
  case ",$F_BOOT," in *",$_s:"*) ;; *) _missing="$_missing $_s" ;; esac
done
_nreg="$(printf '%s\n' $STG_REGISTRY | wc -l | tr -d ' ')"
ck "every registry stage appears in the record (registry: $_nreg stages)${_missing:+ — missing:$_missing}" \
   "$(if [ -z "$_missing" ]; then echo 0; else echo 1; fi)"
_dups="$(printf '%s' "$F_BOOT" | tr ',' '\n' | cut -d: -f1 | sort | uniq -d)"
ck "  …and no stage appears TWICE (a duplicated key is read as the last one, silently)${_dups:+ — dup:$_dups}" \
   "$(if [ -z "$_dups" ]; then echo 0; else echo 1; fi)"
# ⛔ THE PROPERTY THAT MATTERS: adding a stage to the registry is the ONLY edit needed. A change that
# adds a stage at a call site but forgets the registry must fail HERE, not in a record nobody reads.
_saved="$STG_REGISTRY"
STG_REGISTRY="$STG_REGISTRY zz_probe_stage"
stg_field _probe_field
ck "a stage ADDED TO THE REGISTRY alone appears in the record with no second edit (zz_probe_stage:ns)" \
   "$(qF 'zz_probe_stage:ns' "$_probe_field"; ok $?)"
ck "  …and the pre-existing stages are unchanged by that addition" \
   "$(if qF 'boot:' "$_probe_field" && qF 'prev_wait:' "$_probe_field"; then echo 0; else echo 1; fi)"
STG_REGISTRY="$_saved"
stg_field _restored
ck "  …and the extra stage is gone once the registry is restored (the field follows the registry)" \
   "$(if qF 'zz_probe_stage' "$_restored"; then echo 1; else echo 0; fi)"

# ── §5 the tiled stages TILE ───────────────────────────────────────────────────────────────────
echo
echo "── §5 the TILED stages tile the body — their sum is the wall time, so none escapes ──"
# ⛔ MEASURED IN MICROSECONDS, NOT SECONDS. The emitted field truncates each stage to whole seconds,
# so an 11-stage drive in fractions of a second would sum to 0 and this arm would be vacuous. The
# tiling claim is about the instrument, so it is graded on the instrument's own clock.
_el0=0; stg_now_us_vars _el0
stg_cycle_reset
# ⛔ THE SLEEP COMES BEFORE EACH MARK, SO THE LAST MARK CLOSES THE LAST INTERVAL. Sleeping AFTER the
# final mark would leave an un-attributed tail that no stage owns, and the arm would then be grading
# the harness's own tail instead of the tiling.
for _s in $STG_REGISTRY_TILED; do sleep 0.3; stg_mark "$_s"; done
_el1=0; stg_now_us_vars _el1
stg_field _tile_field
_sum_us=0
for _s in $STG_REGISTRY_TILED; do
  _uv="STG_V_${_s}"; _u="${!_uv:-0}"
  case "$_u" in ''|*[!0-9]*) _u=0 ;; esac
  _sum_us=$((_sum_us + _u))
done
_elapsed_us=$(( _el1 - _el0 ))
_delta=$(( _sum_us - _elapsed_us )); [ "$_delta" -ge 0 ] || _delta=$(( -_delta ))
# Tolerance is 250 ms of the ~3.3 s drive: the sinks are the µs bookkeeping and the final stage's
# un-marked tail, NOT truncation. A stage MISSING from the tiling loses ~300 ms of real work here and
# whole MINUTES of it on a real cycle (the 161-minute defect), so the bound is tight on purpose.
ck "the tiled sum accounts for the measured wall time (sum=${_sum_us}us, elapsed=${_elapsed_us}us, delta=${_delta}us)" \
   "$(if [ "$_delta" -le 250000 ]; then echo 0; else echo 1; fi)"
_tile_ns=""
for _s in $STG_REGISTRY_TILED; do
  case ",${_tile_field}," in *",${_s}:ns,"*) _tile_ns="$_tile_ns $_s" ;; esac
done
ck "  …and every TILED stage contributed (none reads ns after a full drive)${_tile_ns:+ — ns:$_tile_ns}" \
   "$(if [ -z "$_tile_ns" ]; then echo 0; else echo 1; fi)"
# An overlay is a BREAKDOWN of the tiled stage it ran inside — never an addition on top of it.
ck "an overlay is CONTAINED by its tiled stage (l4_review=$_l_l4 <= sweep=$_l_sweep), never added on top" \
   "$(if atleast "$_l_sweep" 2 && atleast "$_l_l4" 2 && [ "$_l_l4" -le "$_l_sweep" ]; then echo 0; else echo 1; fi)"

# ── §6 FORK-FREE by construction ───────────────────────────────────────────────────────────────
echo
echo "── §6 the clock is FORK-FREE: it runs before fork_gate, where one \$( ) kills the controller ──"
# Comments in the block NAME `$( )`, `date` and backticks to explain why they are banned, so this is
# asserted against CODE lines only — a structural check that a future edit cannot quietly reintroduce
# a fork on the path agent-infra#2293 measured (a failed fork TERMINATES bash, rc 254).
_code="$TMP/clock-code.sh"
grep -v '^[[:space:]]*#' "$TMP/clock.sh" > "$_code"
_ccode="$(cat "$_code")"
# ⛔ `$((` IS ARITHMETIC, NOT A COMMAND SUBSTITUTION, AND IT IS FORK-FREE. A naive `grep '$(('`
# match flags every `$(( … ))` in the clock — which is the clock's whole arithmetic and therefore its
# hot path. The arithmetic prefix is stripped first, and what remains is only a REAL command
# substitution (`$(cmd)`), which is the thing that forks.
_nocmdsub="$(printf '%s\n' "$_ccode" | sed 's/\$((//g')"
ck "no command substitution in the shipped clock's CODE (a \$( ) here is a fork on the starved path)" \
   "$(if qF '$(' "$_nocmdsub"; then echo 1; else echo 0; fi)"
ck "no backtick substitution either (\`\` forks exactly like \$( ))" \
   "$(if qF '`' "$_ccode"; then echo 1; else echo 0; fi)"
ck "no 'date' fork in the clock's code (the whole point is a clock without a process)" \
   "$(if qF 'date ' "$_ccode"; then echo 1; else echo 0; fi)"
_when="$(awk '/^while true; do/{W=NR} /stg_cycle_reset/{if(!R)R=NR} /^  fork_gate$/{if(!F)F=NR}
                 END{ if (R && F && R < F) print "ok"; else print "bad" }' "$ORCH")"
ck "the reset is called ABOVE fork_gate in the shipped loop (so a starved cycle is timed at all)" \
   "$(if [ "$_when" = "ok" ]; then echo 0; else echo 1; fi)"

# ── §7 BACKWARDS COMPATIBILITY: an old-format record still parses ─────────────────────────────
echo
echo "── §7 an OLD-format record (no stages=) still parses for every reader ──"
O="$TMP/O"; mkdir -p "$O/state"
NOW="$(date +%s)"
# The SHIPPED pre-change fixture shape, byte for byte what a box running the previous release wrote.
OLD="start=$(( NOW - 60 )) end=$(( NOW - 55 )) cycle=7 interval=240 selected=issue:#2216 selected_n=1 dispatched=1 ids=#2216 nothing=none placement=place placed_on=cell-1 bound=none lpc_self=7 shapes=1 spawned_pr=UNMEASURED spawn_tags=UNMEASURED drain=draining"
NEW="start=$NOW end=$(( NOW + 3 )) cycle=8 interval=240 selected=pr:#9 selected_n=2 dispatched=0 ids=- nothing=gate:drain placement=place placed_on=cell-1 bound=none lpc_self=7 shapes=2 spawned_pr=0 spawn_tags=none drain=DEADLOCK stages=boot:3,disk:1,reap:0,refresh:2,authority:1,claims:0,caches:0,sweep:41,gate:6,l5_issue:0,record:0,l1_main:ns,l2_merge:0,l3_fix:12,l4_review:29,prev_wait:241"
printf '%s\n%s\n' "$OLD" "$NEW" > "$O/state/cycles"
V="$(cycle_verdict "$O")"; RC=$?
ck "cycle_verdict grades the NEWEST record HEALTHY with the stages= field present (rc=$RC)" \
   "$(if [ "$RC" -eq 0 ] && qF 'HEALTHY ' "$V"; then echo 0; else echo 1; fi)"
H="$(cycle_history "$O" 10)"
ck "cycle_history prints BOTH records (the old-format line is not dropped by the new field)" \
   "$(if qF 'cycle=7' "$H" && qF 'cycle=8' "$H"; then echo 0; else echo 1; fi)"
_oldline="$(printf '%s\n' "$H" | grep 'cycle=7')"
ck "  …and the old-format line is passed through intact, with no stages= token invented for it" \
   "$(if qF 'stages=' "$_oldline"; then echo 1; else echo 0; fi)"
ck "cycle_stage_get on an OLD-format record answers 'absent' (rc 1), not an error and not a 0" \
   "$(if cycle_stage_get "$OLD" sweep >/dev/null 2>&1; then echo 1; else echo 0; fi)"
_nv="$(cycle_stage_get "$NEW" l4_review)"
ck "  …and on a new-format record it answers the value (l4_review='$_nv')" "$(eqv "$_nv" 29; ok $?)"
ck "  …and absent (rc 1) for a stage the field does not name — an unknown name is never 0" \
   "$(if cycle_stage_get "$NEW" not_a_stage >/dev/null 2>&1; then echo 1; else echo 0; fi)"
# The CLI surface an operator actually runs.
# ⛔ THE PATH BETWEEN `bash` AND THE SCRIPT IS **LITERAL** (`./cycle-record.sh`), AND THAT IS
# LOAD-BEARING FOR THIS SUITE'S RUNNABILITY. The main-worktree-guard's #709 arm reads a script's
# CONTENT and, on seeing `bash "$VAR"`, classifies the invocation as script-indirection with a path
# it cannot statically resolve — and fails CLOSED, refusing to run THIS suite at all. Measured: with
# `bash "$CR"` below, the whole file was refused before line 1 ran (three different guard verdicts
# across three attempts, one of them naming a shell-expansion form that was not in the command). A
# literal relative path is resolvable, so the guard can read the invoked script and let it run.
# ⛔ DO NOT "TIDY" THIS BACK INTO A VARIABLE. `cd` in a subshell keeps the path literal while still
# making the suite independent of the caller's CWD.
_crecord() { ( cd "$HERE" && bash ./cycle-record.sh "$@" ); }
SO="$(_crecord stages --dir "$O" 2>&1)"
_tab_ok() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" -v v="$3" '$1==n && $2==v{f=1} END{exit !f}'; }
ck "the 'stages' CLI verb reports the newest record's breakdown (name<TAB>secs)" \
   "$(_tab_ok "$SO" l4_review 29; ok $?)"
ck "  …including the ns stage, so an unimplemented level is visible from the CLI" \
   "$(_tab_ok "$SO" l1_main ns; ok $?)"
printf '%s\n' "$OLD" > "$O/state/cycles"
SO2="$(_crecord stages --dir "$O" 2>&1)"
ck "  …and on an OLD-ONLY record names the absence instead of failing (NO-STAGE-FIELD)" \
   "$(qF 'NO-STAGE-FIELD' "$SO2"; ok $?)"
ST="$(_crecord status --dir "$O" 2>&1)"
ck "  …and 'status' still grades an OLD-ONLY record (the field is not a precondition for the verdict)" \
   "$(qF 'HEALTHY ' "$ST"; ok $?)"
# `bin/harness` is the OTHER production reader. It consumes records by PASS-THROUGH: `cycle_history`
# renders them and the JSON arm escapes each whole line as a string, so it enumerates no field names
# of its own — which is exactly why a new field cannot break it. Pinned structurally (and driven by
# hand for the PR evidence) rather than invoked, because its landing read reaches for a real `gh`
# chain and this suite is hermetic by contract.
if [ -s "$HARNESS_BIN" ]; then
  ck "bin/harness reads records through cycle_history, not by enumerating fields" \
     "$(qF 'cycle_history' "$(cat "$HARNESS_BIN")"; ok $?)"
  ck "  …and it does not name the new field at all (so the field required no change there)" \
     "$(if qF 'stages=' "$(cat "$HARNESS_BIN")"; then echo 1; else echo 0; fi)"
else
  ck "bin/harness is present (the second reader has coverage)" 1
fi

# ── §8 the record stays ONE space-separated k=v line ──────────────────────────────────────────
echo
echo "── §8 the new field cannot break the record grammar the other twenty fields share ──"
O2="$TMP/O2"; mkdir -p "$O2/state"
cycle_record_write "$O2" start=100 end=103 cycle=1 interval=240 selected=none selected_n=0 \
  dispatched=0 ids=- nothing=none stages="$F_BOOT" >/dev/null
_lines="$(wc -l < "$O2/state/cycles" | tr -d ' ')"
ck "the record is still exactly ONE line (got $_lines)" \
   "$(if [ "$_lines" = "1" ]; then echo 0; else echo 1; fi)"
_rec="$(cat "$O2/state/cycles")"
_stok="$(printf '%s\n' "$_rec" | tr ' ' '\n' | grep '^stages=')"
_stok="${_stok#stages=}"
ck "  …and the stages value came back BYTE-IDENTICAL (no space was introduced, so cr_san did not rewrite it)" \
   "$(eqv "$_stok" "$F_BOOT"; ok $?)"
ck "  …and the value still validates as read back off disk" \
   "$(if cycle_stages_valid "$_stok"; then echo 0; else echo 1; fi)"
ck "  …and the pre-existing fields are untouched beside it (start/cycle/nothing still parse)" \
   "$(if qF 'start=100' "$_rec" && qF 'cycle=1' "$_rec" && qF 'nothing=none' "$_rec"; then echo 0; else echo 1; fi)"
ck "  …so a reader that knows nothing about stages= still finds every field it uses" \
   "$(if qF 'interval=240' "$_rec" && qF 'dispatched=0' "$_rec"; then echo 0; else echo 1; fi)"

echo
# ── §9 the defects a fresh-context review found, now pinned ──────────────────────────────────────
echo "── §9 REGRESSIONS the main-shell drives above could never catch (subshell, carry, call site) ──"

# 9.1 AN OVERLAY CLOSED INSIDE A PIPELINE SUBSHELL MUST REACH THE RECORD.
# The real sweep is `printf … | while read … done`, so `stg_lvl_settle` runs in a SUBSHELL. The shipped
# code queues the interval in `$STG_LVL_TMP` and folds it in the parent; the pre-review code called
# `stg_add` there and the write died at `done`, so every record said `l2_merge:0` whatever happened.
# This arm drives that exact boundary — it is the only arm in the suite that does.
STG_LVL_TMP="$TMP/lvlq"; : >"$STG_LVL_TMP"
STG_V_l2_merge=0; STG_V_l3_fix=0; STG_V_l4_review=0; STG_OPEN_LVL=""; STG_OPEN_T0=0
printf 'row\n' | while read -r _prow; do
  stg_lvl_start l2_merge || :
  sleep 1.2
  stg_lvl_settle || :
done
ck "an overlay interval opened INSIDE a pipeline has NOT yet reached the parent (the variable is still 0)" \
   "$(if [ "${STG_V_l2_merge:-0}" -eq 0 ]; then echo 0; else echo 1; fi)"
stg_lvl_fold || :
ck "  …and the FOLD turns that queued interval into the level's measured time (got ${STG_V_l2_merge:-0} us)" \
   "$(if [ "${STG_V_l2_merge:-0}" -ge 1000000 ]; then echo 0; else echo 1; fi)"
stg_lvl_fold || :
ck "  …and folding twice adds nothing (the queue is drained), still ${STG_V_l2_merge:-0} us" \
   "$(if [ "${STG_V_l2_merge:-0}" -lt 3000000 ]; then echo 0; else echo 1; fi)"
ck "  …and a level with no interval is still a MEASURED 0, not an accident of the mechanism" \
   "$(if [ "${STG_V_l3_fix:-x}" = "0" ]; then echo 0; else echo 1; fi)"
STG_LVL_TMP=""

# 9.1b THE LAST ROW'S OPEN INTERVAL MUST NOT DIE AT `done`.
# The top-of-iteration settle closes the PREVIOUS row's level, so the FINAL row had no closer and its
# interval died with the subshell. Measured before the fix: three 1 s rows accumulated 2004 us x 1000
# instead of ~3000 — one row's worth of cascade dropped in EVERY cycle. This arm drives the shipped
# loop's own arrangement (settle at top AND at the end of the body) over three rows.
STG_LVL_TMP="$TMP/lvlq2"; : >"$STG_LVL_TMP"
STG_V_l2_merge=0; STG_OPEN_LVL=""; STG_OPEN_T0=0
printf 'r1\nr2\nr3\n' | while read -r _prow; do
  stg_lvl_settle || :
  stg_lvl_start l2_merge || :
  sleep 1
  stg_lvl_settle || :
done
stg_lvl_fold || :
ck "three 1 s rows accumulate ~3 intervals, not 2 — the LAST row's interval is not lost at 'done' (got ${STG_V_l2_merge:-0} us)" \
   "$(if [ "${STG_V_l2_merge:-0}" -ge 2700000 ]; then echo 0; else echo 1; fi)"
STG_LVL_TMP=""

# 9.1c THE TWO SHIPPED CALL SITES THE FIX DEPENDS ON MUST EXIST IN `orch-loop.sh`.
# §9.1/§9.1b drive an arrangement the suite writes ITSELF, so neither can see whether the SHIPPED
# loop performs that arrangement (second fresh-context review, P1: deleting the shipped trailing
# settle and the shipped post-`done` fold left the suite at "72 passed"). These two arms read the
# real file. Comments are NOT stripped here on purpose — the assertion is about executable lines, so
# it matches only lines that are not full-line comments AND names the exact call.
_loop_nc="$(grep -vE '^[[:space:]]*#' "$ORCH")"
ck "the shipped sweep SETTLES at the end of the body — 'stg_lvl_settle || :' immediately before its 'done'" \
   "$(if printf '%s\n' "$_loop_nc" | awk '/stg_lvl_settle \|\| :/ {seen=1; next} seen && /^[[:space:]]*done[[:space:]]*$/ {found=1} END {exit !found}'; then echo 0; else echo 1; fi)"
ck "the shipped sweep FOLDS the overlay queue in the PARENT, after 'done' — 'stg_lvl_fold' before 'stg_mark sweep'" \
   "$(if printf '%s\n' "$_loop_nc" | awk '/done$/ {after=1} after && /stg_lvl_fold/ {f=1} END {exit !f}'; then echo 0; else echo 1; fi)"
# ⛔ AND EVERY `stg_nap_mark` CALL SITE MUST SAMPLE `STG_WAIT_T0` FIRST. `stg_cycle_reset` zeroes that
# sample, so a call site that omits it records the controller's WHOLE UPTIME as "the gap" — measured
# 3004153 us for a 1000000 us nap on the disk-held arm, which is the fabricated-measurement class
# this field exists to end. The disk-held arm shipped with exactly that omission, so this arm pins
# the CLASS, not the one site: any future nap site that forgets the sample reds here.
_nap_bad=""
for _nln in $(printf '%s\n' "$_loop_nc" | grep -n '^[[:space:]]*stg_nap_mark[[:space:]]*$' | cut -d: -f1); do
  _win="$(printf '%s\n' "$_loop_nc" | sed -n "$(( _nln > 4 ? _nln - 4 : 1 )),$(( _nln - 1 ))p")"
  case "$_win" in *'STG_WAIT_T0='*) : ;; *) _nap_bad="$_nap_bad $_nln" ;; esac
done
ck "every stg_nap_mark call site samples STG_WAIT_T0 first, so prev_wait cannot become the process uptime${_nap_bad:+ (bad line(s):$_nap_bad)}" \
   "$([ -z "$_nap_bad" ] && echo 0 || echo 1)"

# 9.2 `prev_wait` IS ONE GAP, NOT THE LIFETIME SUM OF EVERY NAP.
# `stg_add` accumulates, so the pre-review `stg_nap_mark` made the field grow every cycle (measured
# 1,2,3 over three 1 s naps; on a real box with CYC=240 it reaches ~2400 by cycle 10). Two resets and
# two naps is exactly the sequence that produced that, so this arm fails on the old code.
stg_cycle_reset
stg_now_us_vars _pt1 >/dev/null 2>&1 || _pt1=0
STG_WAIT_T0=$(( _pt1 - 1000000 )); stg_nap_mark
_pw1="${STG_V_prev_wait:-}"
stg_cycle_reset                      # next cycle: the reset deliberately CARRIES prev_wait
ck "the reset CARRIES prev_wait (it is the previous gap, by definition read one cycle later)" \
   "$(if [ -n "${STG_V_prev_wait:-}" ]; then echo 0; else echo 1; fi)"
stg_now_us_vars _pt2 >/dev/null 2>&1 || _pt2=0
STG_WAIT_T0=$(( _pt2 - 1000000 )); stg_nap_mark
_pw2="${STG_V_prev_wait:-0}"
ck "a SECOND cycle's nap OVERWRITES prev_wait instead of adding to it (1st ${_pw1:-?} us, 2nd ${_pw2} us)" \
   "$(if [ "$_pw2" -lt 1500000 ]; then echo 0; else echo 1; fi)"
ck "  …and the second gap is a real measurement, not a cleared-to-zero field" \
   "$(if [ "$_pw2" -ge 1000000 ]; then echo 0; else echo 1; fi)"

# 9.3 EVERY DECLARED CASCADE LEVEL HAS A REAL CALL SITE.
# `l4_review` was declared in `STG_REGISTRY_LVL` (so the reset initialised it to `0`, "a MEASURED
# zero") while nothing ever called `stg_lvl_start l4_review` — the exact false pass this file refuses
# for `l1_main`. Asserts against the SHIPPED loop, with FULL-LINE COMMENTS STRIPPED first: a comment
# that merely names the call must not satisfy the arm (the fix for this defect explains itself in
# prose, so an unstripped grep would have passed on the broken tree).
_loopcode="$(grep -vE '^[[:space:]]*#' "$ORCH")"
for _lvl in $STG_REGISTRY_LVL; do
  ck "cascade level '$_lvl' has a stg_lvl_start call site in the shipped loop (not just a registry entry)" \
     "$(if qF "stg_lvl_start $_lvl" "$_loopcode"; then echo 0; else echo 1; fi)"
done

# 9.4 THE READER REFUSES A CORRUPT VALUE INSTEAD OF RETURNING IT.
# `a:1:2` used to answer `1:2` and `a:` the empty string, BOTH rc 0 — a caller could not tell a corrupt
# value from a measurement, which defeats the one property the field exists to have.
ck "cycle_stage_get answers ABSENT for a value with a second colon ('1:2' is not a duration)" \
   "$(if cycle_stage_get 'start=1 stages=sweep:1:2' sweep >/dev/null 2>&1; then echo 1; else echo 0; fi)"
ck "  …and ABSENT for a stage named with no value at all — a REFUSAL (rc≠0), because an empty string with rc 0 is indistinguishable from a reading at the call site" \
   "$(if cycle_stage_get 'start=1 stages=sweep:' sweep >/dev/null 2>&1; then echo 1; else echo 0; fi)"
ck "  …and ABSENT for a non-numeric value" \
   "$(if cycle_stage_get 'start=1 stages=sweep:abc' sweep >/dev/null 2>&1; then echo 1; else echo 0; fi)"
ck "  …while a real value and 'ns' are still returned unchanged" \
   "$(if [ "$(cycle_stage_get 'stages=sweep:41,l4_review:ns' sweep)" = "41" ] && \
         [ "$(cycle_stage_get 'stages=sweep:41,l4_review:ns' l4_review)" = "ns" ]; then echo 0; else echo 1; fi)"

# 9.5 THE `record` STAGE MAY NOT BE MARKED AFTER THE PREPARATION IT NAMES.
# The marks used to sit immediately above `stg_field`, i.e. AFTER the `tr`/`sed`/`cut` work, so that
# work was credited to `l5_issue` and `record` measured two adjacent calls. Asserts ORDER in the
# shipped loop: the `stg_mark record` line precedes the `_cr_ids` preparation it claims to measure.
_rec_line="$(grep -n 'stg_mark record' "$ORCH" | grep -vE ':[[:space:]]*#' | head -1 | cut -d: -f1)"
_cprep="$(grep -n '_cr_ids="\$(tr' "$ORCH" | head -1 | cut -d: -f1)"
ck "stg_mark record precedes the ids=/selected= preparation it measures (record line ${_rec_line:-?}, prep line ${_cprep:-?})" \
   "$(if [ -n "$_rec_line" ] && [ -n "$_cprep" ] && [ "$_rec_line" -lt "$_cprep" ]; then echo 0; else echo 1; fi)"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
