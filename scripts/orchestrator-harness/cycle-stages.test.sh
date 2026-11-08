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
#   §9.1c–f THE SHIPPED WIRING — the mechanisms are graded at their real call sites, not only through
#       arrangements this suite writes itself: the trailing settle, the post-`done` fold, each nap's
#       pre-nap stamp, `stages=` on BOTH early-exit records, a mark site for every TILED stage,
#       `stg_field`'s own fold, and the monotonic clamp. Added because TWENTY-TWO mutations of the
#       shipped arrangement and reader left the earlier suite fully green.
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
# ⛔ ONE STRIPPER, THREE VIEWS, DEFINED BEFORE ANY ARM USES THEM. `_strip_tc` removes a TRAILING
# ` #…` from every CODE line and leaves FULL-LINE comments alone; `_loop_nc` then drops those comment
# lines too. Both views are needed: the structural arms want no comments at all (prose must not
# re-supply a deleted call — measured: a deleted `stg_lvl_start l4_review` re-supplied as a trailing
# comment stayed GREEN), while the region arms need the `# [redfix:begin]`-style MARKERS, which ARE
# comment lines (and a full-line-comment strip deletes them).
_strip_tc() { awk '{ if ($0 ~ /^[[:space:]]*#/) { print; next } sub(/[[:space:]]#.*$/, ""); print }' "$1"; }
_loop_tc="$(_strip_tc "$ORCH")"
_loop_nc="$(printf '%s\n' "$_loop_tc" | grep -vE '^[[:space:]]*#')"
echo "==> cycle-stages self-test ($HERE)"

# ── §0 sources, and the existence gate that stops an absence scoring as a pass ────────────────
echo
echo "── §0 both shipped modules are sourced, and every function this suite calls exists ──"
sed -n '/# \[stageclock:begin\]/,/# \[stageclock:end\]/p' "$ORCH" | sed '1d;$d' > "$TMP/clock.sh"
# ⛔ A MISSING DELIMITER MUST ABORT, NOT SILENTLY EXTRACT THE WHOLE CONTROLLER (fresh-context review,
# P3 — measured). `sed -n '/begin/,/end/p'` with the end marker deleted runs to EOF, and `1d;$d` then
# shaves one line at each end — so `clock.sh` became ~6800 lines INCLUDING `while true; do`, the registry
# token was still present, and §0 ACCEPTED it and then ran `. "$TMP/clock.sh"`: the guard suite would
# dispatch lanes, run git and call gh. Fail-OPEN in the one direction that matters, so the extraction is
# now bounded and shape-checked before anything is sourced.
_clock_lines="$(wc -l < "$TMP/clock.sh" 2>/dev/null | tr -d ' ')"
_clock_bad=""
[ -s "$TMP/clock.sh" ] || _clock_bad="$_clock_bad empty"
qF 'STG_REGISTRY_TILED=' "$(cat "$TMP/clock.sh")" || _clock_bad="$_clock_bad no-registry"
[ "${_clock_lines:-0}" -le 400 ] || _clock_bad="$_clock_bad too-wide(${_clock_lines})"
grep -qE '^[[:space:]]*while true; do' "$TMP/clock.sh" && _clock_bad="$_clock_bad contains-the-controller-loop"
if [ -z "$_clock_bad" ]; then
  ck "the stage-clock block is extracted from the shipped loop (${_clock_lines} lines, bounded and shape-checked)" 0
else
  ck "the stage-clock block is extracted from the shipped loop" 1
  echo "❌ extraction FAILED or was UNBOUNDED (${_clock_bad# }) — aborting: sourcing an unbounded extraction"
  echo "   would RUN the controller loop, so this suite must never do it (a missing [stageclock:end] marker"
  echo "   is the way it happens). Restore the marker in orch-loop.sh."
  exit 2
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
ck "  …and no stage appears TWICE (a duplicated key is read as the FIRST one, silently)${_dups:+ — dup:$_dups}" \
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
# ⛔ THIS ARM USED TO BE VACUOUS (third fresh-context review, P0): the pattern `/stg_cycle_reset/`
# matched the DOC COMMENT at the function definition, which sits above `fork_gate` — so moving the real
# CALL below the gate left the suite at 75 passed. Fixed by stripping full-line comments and keying on
# the CALL ONLY (`^  stg_cycle_reset$`), so the prose cannot satisfy its own arm.
_loopcode6="$(printf '%s\n' "$_loop_tc" | grep -vE '^[[:space:]]*#')"
_when="$(printf '%s\n' "$_loopcode6" | awk '/^while true; do/{W=NR} /^[[:space:]]*stg_cycle_reset[[:space:]]*$/{if(!R)R=NR} /^  fork_gate$/{if(!F)F=NR}
                 END{ if (R && F && R < F) print "ok"; else print "bad" }')"
ck "the reset is CALLED (not merely defined) above fork_gate in the shipped loop (so a starved cycle is timed at all)" \
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
# ⛔ A RECORD THAT CANNOT BE READ IS NOT A PRE-FIELD RECORD (fresh-context review, P2 — measured).
# `[ -s ]` is a STAT, not a read: a non-empty `state/cycles` the process cannot read (a mode-000 file, or
# — as driven here, so the arm works for root too — a DIRECTORY at that path) passed the size test,
# `tail`'s error was swallowed by `2>/dev/null`, and the empty read took the NO-STAGE-FIELD branch: rc 0
# and the words "this is NOT an error" for a record that was never read, while `status`/`history`
# answered UNREADABLE rc 2 on the SAME state. That inverts this module's own EXIT contract.
O3="$TMP/O3"; mkdir -p "$O3/state/cycles"
SO3="$(_crecord stages --dir "$O3" 2>&1)"; _so3rc=$?
SO3v="$(_crecord status --dir "$O3" 2>&1)"; _so3vrc=$?
ck "an UNREADABLE newest record answers UNREADABLE rc 2, not the rc-0 'this is NOT an error' branch (stages rc=${_so3rc}, '${SO3%% *}'; status rc=${_so3vrc})" \
   "$(if [ "${_so3rc:-0}" = "2" ] && qF 'UNREADABLE' "${SO3:-}" && [ "${_so3vrc:-0}" = "2" ]; then echo 0; else echo 1; fi)"
ck "  …and a genuinely READABLE old-format record still answers NO-STAGE-FIELD rc 0 (the two are not conflated)" \
   "$(printf '%s\n' "$OLD" > "$O/state/cycles"; _so4="$(_crecord stages --dir "$O" 2>&1)"; _so4rc=$?; if [ "${_so4rc:-9}" = "0" ] && qF 'NO-STAGE-FIELD' "$_so4"; then echo 0; else echo 1; fi)"
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
STG_LVL_TMP="$TMP/lvlq"
stg_cycle_reset                      # the REAL initialiser: levels become "" (ns), the queue is truncated
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
_v_after_1="${STG_V_l2_merge:-0}"
stg_lvl_fold || :
# ⛔ EQUALITY, NOT A CEILING (fourth fresh-context review, P1 — measured). An absolute `< 3000000` bound
# was satisfied by ONE duplicated fold of a 1.2 s interval, so a `stg_lvl_fold` that never truncated its
# queue — double counting EVERY overlay interval in EVERY record, the pyramid-fill defect this field
# exists to prevent — stayed GREEN (83/0; measured after fold2 2404098, after fold3 3606147).
ck "  …and folding twice adds nothing at all — the queue is drained (after 1 fold ${_v_after_1} us, after 2 ${STG_V_l2_merge:-0} us)" \
   "$(if [ "${STG_V_l2_merge:-X}" = "${_v_after_1}" ] && [ "${_v_after_1}" -ge 1000000 ]; then echo 0; else echo 1; fi)"
ck "  …and a level with no interval is 'ns' — never a measured-looking 0 for a level nothing entered" \
   "$(if [ "${STG_V_l3_fix-UNSET}" = "" ]; then echo 0; else echo 1; fi)"
STG_LVL_TMP=""

# 9.1b THE LAST ROW'S OPEN INTERVAL MUST NOT DIE AT `done`.
# The top-of-iteration settle closes the PREVIOUS row's level, so the FINAL row had no closer and its
# interval died with the subshell. Measured before the fix: three 1 s rows accumulated 2004 us x 1000
# instead of ~3000 — one row's worth of cascade dropped in EVERY cycle.
# ⛔ THIS ARM WRITES THAT ARRANGEMENT ITSELF — it does NOT read the shipped loop, and the earlier text
# here said otherwise (sixth fresh-context review, P3 — measured: deleting the shipped TOP-OF-ROW
# `stg_lvl_settle` leaves this arm green). The shipped settle sites are graded by §9.1c, which reads
# `orch-loop.sh`; the top-of-row one is graded separately, by §9.1d-xi below.
# ⛔ AND THE REASON IT IS NEEDED IS THE OPPOSITE OF WHAT THIS COMMENT USED TO SAY (fresh-context review,
# P3 — driven). It claimed the next row's `stg_lvl_start` settles it anyway and the loss is "a bounded
# per-row sliver". Removing it does not LOSE a sliver, it ADDS the next row's head into the previous
# row's level: driven through the shipped clock, two rows of [1 s head][1 s l3 work][continue] report
# `l3_fix=1001 ms` WITH the settle and `l3_fix=2004 ms` WITHOUT it. In production that extra second is
# the next row's `HEAD_N=$(gh pr view …)` (plus `gh pr ready` for a draft) — a network round trip
# charged to a cascade level of a DIFFERENT PR, which is the #2028 class this field exists to end.
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
# ⛔ FULL-LINE STRIPPING IS NOT ENOUGH, AND EVERY COUNT/GREP ARM BELOW DEPENDS ON THIS (sixth
# fresh-context review, P2 — measured). `grep -vE '^[[:space:]]*#'` leaves TRAILING comments in the
# stream, so deleting a real call and leaving `: # (was: stg_lvl_start l4_review)` on any code line
# re-supplies the token the arm greps for. Measured: the plain deletions redden (92/1) and the
# prose-satisfied forms stayed at 93/0 — for `stg_lvl_start l4_review` (this PR's own P0 fix),
# `stg_field STG_FIELD` and `stages="${STG_FIELD:-}"` alike. So trailing comments are stripped too, and
# every pattern that matters is anchored at `^[[:space:]]*<identifier>`.
# ⛔ THE SETTLE ARM MUST REQUIRE THE **ADJACENT** LINE, NOT "SOME settle before SOME done" (my own
# first draft of this arm was VACUOUS: it matched the TOP-OF-LOOP settle and stayed green after the
# shipped end-of-body settle was deleted — verified, 75 passed with the line removed). The top-of-loop
# settle exists on every iteration, so only adjacency to `done` distinguishes the two.
ck "the shipped sweep SETTLES as its LAST statement — an ANCHORED 'stg_lvl_settle || :' immediately before its 'done'" \
   "$(if printf '%s\n' "$_loop_nc" | awk 'prev ~ /^[[:space:]]*stg_lvl_settle[[:space:]]*\|\|[[:space:]]*:/ && $0 ~ /^[[:space:]]*done[[:space:]]*$/ {found=1} {prev=$0} END {exit !found}'; then echo 0; else echo 1; fi)"
# ⛔ AND IT MUST MATCH THE SWEEP'S OWN CALL, NOT `stg_field`'s (my second draft of this arm was
# VACUOUS: `stg_field` is DEFINED after the sweep's `done` and its body contains a bare `stg_lvl_fold`,
# so deleting the shipped post-`done` fold stayed GREEN — verified). The sweep's call is spelled
# `stg_lvl_fold || :`, which is the form only that call site uses.
ck "the shipped sweep FOLDS the overlay queue AFTER its 'done', in the parent ('stg_lvl_fold || :' after a 'done')" \
   "$(if printf '%s\n' "$_loop_nc" | awk '$0 ~ /^[[:space:]]*done[[:space:]]*$/ {after=1} after && /^[[:space:]]*stg_lvl_fold[[:space:]]*\|\|[[:space:]]*:/ {f=1} END {exit !f}'; then echo 0; else echo 1; fi)"
# ⛔ AND EVERY `stg_nap_mark` CALL SITE MUST SAMPLE `STG_WAIT_T0` **BEFORE THE NAP**, NOT MERELY NEAR
# IT. `stg_cycle_reset` zeroes that sample and `stg_nap_mark` computes `now - STG_WAIT_T0`, so:
#   · no sample          ⇒ `prev_wait` = the controller's whole uptime (measured 3004153 us for a 1 s nap);
#   · sample AFTER the nap ⇒ `prev_wait` = a fabricated `0` (measured 0 us for a 1 s nap).
# ⛔ A PROXIMITY WINDOW WAS VACUOUS (third fresh-context review): "some line within 4 above contains
# `STG_WAIT_T0=`" was satisfied by the sample placed AFTER the nap — the exact defect it was meant to
# catch. This arm now requires ORDER: the nearest preceding sample line must contain the real call
# (`stg_now_us_vars STG_WAIT_T0`), and it must NOT be preceded-in-window by a `STG_WAIT_T0=0` reset
# without a re-sample. It also refuses a constant `STG_WAIT_T0=0` as the "sample".
# ⛔ THE SITE SPELLING MUST ALLOW A TRAILING COMMENT, OR THE ARM SILENTLY SKIPS A THIRD OF ITS SUBJECTS
# (fourth fresh-context review, P1 — measured). The fork-starved site is
# `    stg_nap_mark        # CARRIED into the NEXT cycle's \`prev_wait\` …`, so the `…[[:space:]]*$`
# spelling matched only TWO of the three sites and deleting the fork-starved arm's sample stayed
# GREEN (83/0).
# ⛔ AND THE SAMPLE MUST BE THE LAST WORD BEFORE THE NAP: a bare `STG_WAIT_T0=0` line inserted BETWEEN
# the sample and the nap re-zeroes the stamp and reproduces the uptime defect while a proximity test
# still passes (measured 83/0). A window-glob cannot tell the two apart — this walks the stripped code
# line by line, so it sees ORDER and a CLOBBER independently.
# ⛔ THE WALK MUST KNOW THE NAP LINE. Without a pattern for it, "a sample precedes the mark" is ALSO
# satisfied by a sample taken BETWEEN the nap and the mark — and that ordering is the other half of the
# defect: `sample AFTER the nap` makes `prev_wait` a fabricated 0 for the whole gap, on every cycle
# (measured on the shipped clock: 1 s nap ⇒ prev_wait 129 us). The sixth fresh-context review found
# exactly that: swapping the two lines in all three sites left the suite at 93/0. So the walk latches
# `nap`, and requires BOTH `have==1` AND `nap==1` at the mark.
_nap_rep="$(printf '%s\n' "$_loop_nc" | awk '
  /^[[:space:]]*stg_cycle_reset[[:space:]]*$/ { have=0; nap=0; next }
  /^[[:space:]]*stg_now_us_vars STG_WAIT_T0([[:space:]]|$)/ { have=1; next }
  /^[[:space:]]*STG_WAIT_T0=0[[:space:]]*$/ { if (have) have="clobber"; next }
  /^[[:space:]]*(fork_free_sleep|sleep)([[:space:]]|$)/ { if (have) nap=1; next }
  /^[[:space:]]*stg_nap_mark([[:space:]]|$)/ {
    sites++
    if (have == 1 && nap == 1) ok++
    else bad = bad sprintf(" line=%d(%s)", NR, \
      (have == "clobber" ? "clobbered" : (have != 1 ? "no-sample" : "sampled-AFTER-the-nap")))
    have = 0; nap = 0; next
  }
  END { printf "%d %d%s", sites+0, ok+0, bad }')"
_nap_sites="${_nap_rep%% *}"
_nap_okc="$(printf '%s' "$_nap_rep" | cut -d' ' -f2)"
_nap_bad="$(printf '%s' "$_nap_rep" | cut -d' ' -f3- | sed 's/^ *//')"
ck "  …and all THREE nap sites were actually inspected (got ${_nap_sites:-0}) — a site the pattern cannot spell is ungraded" \
   "$(if [ "${_nap_sites:-0}" -ge 3 ]; then echo 0; else echo 1; fi)"
ck "every stg_nap_mark call site samples STG_WAIT_T0 BEFORE the nap, with no clobber in between (${_nap_okc}/${_nap_sites:-0} ok)${_nap_bad:+ — bad:$_nap_bad}" \
   "$(if [ "${_nap_sites:-0}" -ge 3 ] && [ "${_nap_okc:-0}" = "${_nap_sites:-0}" ]; then echo 0; else echo 1; fi)"

# 9.1d THE REST OF THE SHIPPED WIRING — the holes 9.1c did not reach (this review, measured).
# Every arm below was GREEN before it existed: deleting the `stages=` field from either early-exit
# record, deleting a tiled stage's `stg_mark` call site, deleting the disk-held arm's `stg_nap_mark`,
# deleting `stg_field`'s own fold, and removing the monotonic clamp ALL left the suite at 76/0.
# 9.1d-i: EVERY `cycle_record_write` CARRIES A **VALID** `stages=`, DERIVED FROM THE SITE COUNT.
# These early-exit arms are the cycles that produced NOTHING — the ones an operator most needs to
# attribute, and the ones the docs call "the very arms the 161-minute narrative is about".
# ⛔ THREE VACUITIES WERE MEASURED HERE (fourth fresh-context review), all now closed:
#   · a `-ge 3` FLOOR cannot see a FOURTH record site added later without the field (measured 83/0);
#   · grading the `stages=` TOKEN only cannot see the `stg_field STG_FIELD` CALL deleted, which writes
#     `stages=` with an EMPTY value — `cycle_stages_valid` refuses it, `cycle-record.sh stages` answers
#     `UNREADABLE`, and `status` still reads HEALTHY (measured 83/0 on BOTH arms);
#   · grading one global `stg_mark <stage>` site cannot see the mark deleted from an early-exit arm,
#     where the stage then reads `ns` on a cycle where it DID run (measured 83/0 for boot and disk).
_writes_n="$(printf '%s\n' "$_loop_nc" | grep -c 'cycle_record_write "\$O"')"
_emit_n="$(printf '%s\n' "$_loop_nc" | grep -c 'stages="\${STG_FIELD:-}"')"
ck "EVERY cycle_record_write site carries stages= (${_emit_n} of ${_writes_n} — derived, not a floor)" \
   "$(if [ "${_writes_n:-0}" -ge 3 ] && [ "${_emit_n:-0}" = "${_writes_n:-0}" ]; then echo 0; else echo 1; fi)"
# The emitter must be CALLED, once per record-write site — a token alone writes an EMPTY field, which
# `cycle_stages_valid` refuses. Counts are DERIVED from the record-write sites, not hardcoded.
_sf_calls="$(printf '%s\n' "$_loop_nc" | grep -c 'stg_field STG_FIELD')"
# ⛔ AND `stages=` MUST BE GRADED PER SITE, NOT BY A GLOBAL COUNT (fresh-context review, P3 — measured):
# deleting the disk-held record's `stages=` line and adding the same token as a no-op on any other code
# line kept both counts equal and the suite GREEN at 101/0 — the early-exit cycle then wrote a record
# with NO `stages=` token at all, on the arm the docs call "the very arms the 161-minute narrative is
# about". So each `cycle_record_write "$O"` INVOCATION BLOCK (through its last `\\`-continued line) must
# carry the field itself; a token anywhere else cannot satisfy it.
_cw_missing=""; _cw_n=0
while read -r _cw_ln; do
  [ -n "${_cw_ln:-}" ] || continue
  _cw_n=$(( _cw_n + 1 ))
  _cw_blk="$(awk -v s="$_cw_ln" 'NR >= s { print; if ($0 !~ /\\$/) exit }' <<<"$_loop_nc")"
  case "$_cw_blk" in *'stages="${STG_FIELD:-}"'*) : ;; *) _cw_missing="$_cw_missing $_cw_ln" ;; esac
done <<<"$(grep -n 'cycle_record_write "\$O"' <<<"$_loop_nc" | cut -d: -f1)"
ck "  …and every cycle_record_write INVOCATION carries its own stages= (${_cw_n:-0} sites${_cw_missing:+, MISSING at:$_cw_missing})" \
   "$(if [ "${_cw_n:-0}" -ge 3 ] && [ -z "$_cw_missing" ]; then echo 0; else echo 1; fi)"
ck "  …and stg_field is CALLED once per record-write site, not just its token written (${_sf_calls} of ${_writes_n})" \
   "$(if [ "${_sf_calls:-0}" = "${_writes_n:-0}" ]; then echo 0; else echo 1; fi)"
# The grammar end of it, driven: an empty value is REFUSED, so the failure above is not cosmetic.
ck "  …and an EMPTY stages= value is refused by the reader's own grammar (so the above is a real break)" \
   "$(if cycle_stages_valid ""; then echo 1; else echo 0; fi)"

# 9.1d-ii: EVERY TILED STAGE HAS A MARK SITE, INCLUDING ONE PER EARLY-EXIT ARM.
# §4 proves the EMITTER walks the registry, so a registered stage always APPEARS — and can appear as
# `ns` forever if nothing ever marks it. That is a missing instrument wearing a valid label.
# ⛔ A SINGLE GLOBAL SITE IS NOT ENOUGH (fourth fresh-context review, P3 — measured): `boot` and `disk`
# each have TWO sites, one on the main path and one in the corresponding early-exit arm, and deleting
# the arm's own mark made that stage read `ns` on a cycle where it DID run — GREEN at 83/0. So the
# requirement is one site per STAGE and, for the two stages the early exits mark, one per ARM as well.
# ⛔ FED BY A HERE-STRING, NOT A PIPE (this suite's own header forbids `… | grep -q …`): under
# `pipefail` a quiet grep exits at its first match while the writer is still pushing, the writer takes
# SIGPIPE, and the pipeline reports the WRITER's status — so the `||` branch fires on a file that DOES
# contain the mark and `unmarked:` names a false FAIL. `scripts/check-no-sigpipe-grep.sh` (a REQUIRED
# check) flags the piped form; the payload here is `_loop_nc` at ~197 KB, well past the pipe buffer, so
# the window is real rather than theoretical.
_unmarked=""
for _s in $STG_REGISTRY_TILED; do
  grep -qE "^[[:space:]]*stg_mark $_s([[:space:]]|\$|;|\|)" <<<"$_loop_nc" || _unmarked="$_unmarked $_s"
done
ck "every TILED stage has a stg_mark call site in the shipped loop${_unmarked:+ — unmarked:$_unmarked}" \
   "$(if [ -z "$_unmarked" ]; then echo 0; else echo 1; fi)"
# ⛔ A COUNT OF TWO IS NOT AN ARM (sixth fresh-context review, P2 — measured): deleting the fork-starved
# arm's `stg_mark boot` and adding a SECOND `stg_mark boot` on the main path left the suite at 93/0, and
# the production effect is that a fork-starved cycle's record reads `boot:ns` even though `boot` — the
# fork probe — is the one stage that DID complete, on exactly the cycles this field exists to explain.
# So the requirement is ADJACENCY INSIDE THE ARM: each early-exit `stg_field STG_FIELD` must be
# immediately preceded, in stripped code, by the `stg_mark` for the stage that arm actually ran.
_arm_marks="$(printf '%s\n' "$_loop_nc" | awk '
  /^[[:space:]]*stg_mark ([A-Za-z0-9_]+)[[:space:]]*$/ { pending=$2; next }
  /^[[:space:]]*stg_field STG_FIELD[[:space:]]*$/ { if (pending != "") out = out " " pending; pending=""; next }
  /^[[:space:]]*$/ { next }
  { if ($0 !~ /^[[:space:]]*(fi|then|do|else)$/) pending="" }
  END { print out }')"
_mkmiss=""
case " $_arm_marks " in *" boot "*) : ;; *) _mkmiss="$_mkmiss boot" ;; esac
case " $_arm_marks " in *" disk "*) : ;; *) _mkmiss="$_mkmiss disk" ;; esac
ck "each EARLY-EXIT arm marks the stage it actually ran, ADJACENT to its own stg_field call (got '${_arm_marks:- none}')${_mkmiss:+ — missing:$_mkmiss}" \
   "$(if [ -z "$_mkmiss" ]; then echo 0; else echo 1; fi)"
# ⛔ AND THE **MAIN-PATH** MARK IS ITS OWN ARM (fresh-context review, P2 — measured). The two arms above
# grade "a site exists per stage" (satisfied by an early-exit arm's mark alone) and "each early-exit arm
# marks its own stage" (satisfied by the main path) — so the MAIN-PATH mark of a doubly-marked stage was
# invisible. Measured: deleting `stg_mark boot` (the fork probe, on the normal cycle path) or `stg_mark
# disk` (the disk-floor gate and its reclaim pass) left the suite at 118/0, while the emitted field became
# `boot:ns, disk:2` or `disk:ns, reap:2` — a stage that DID run labelled "never sampled" and its seconds
# charged to its neighbour. That is the identical vacuity shape the comment above documents catching in
# the OTHER direction. A "main-path" mark is one whose next non-blank stripped line is NOT the arm's own
# `stg_field`, i.e. not the mark consumed by an early-exit arm.
_main_marks="$(printf '%s\n' "$_loop_nc" | awk '
  /^[[:space:]]*stg_mark ([A-Za-z0-9_]+)[[:space:]]*$/ { pending=$2; next }
  /^[[:space:]]*stg_field STG_FIELD[[:space:]]*$/ { pending=""; next }
  /^[[:space:]]*$/ { next }
  { if ($0 !~ /^[[:space:]]*(fi|then|do|else)$/) { if (pending != "") out = out " " pending; pending="" } }
  END { print out }')"
_mmmiss=""
case " $_main_marks " in *" boot "*) : ;; *) _mmmiss="$_mmmiss boot" ;; esac
case " $_main_marks " in *" disk "*) : ;; *) _mmmiss="$_mmmiss disk" ;; esac
ck "  …and the MAIN-PATH mark survives for a doubly-marked stage, so a stage that ran cannot read 'ns' (got '${_main_marks:- none}')${_mmmiss:+ — missing:$_mmmiss}" \
   "$(if [ -z "$_mmmiss" ]; then echo 0; else echo 1; fi)"

# ⛔ AND THE **BODY ORDER** OF THE TILED MARKS, WHICH NOTHING GRADED (fresh-context review, P2 — measured).
# `stg_mark X` closes the preceding span INTO `X`, so the ORDER is what makes the attribution correct — and
# every arm above grades existence, not order. Measured: swapping `claims`↔`caches`, swapping
# `reap`↔`refresh`, swapping the MAIN-PATH `boot`↔`disk`, and moving `stg_mark gate` up beside the per-PR
# `sweep` ALL left the suite at 119/0. The last is the damaging shape: the entire fleet-placement /
# CI-queue / gate-vector block was booked to `l5_issue`, reproducing the `sweep`/`gate` misattribution this
# PR exists to fix with one line moved — and because every stage still reads a NUMBER (never `ns`), no other
# arm can see it. The expected sequence is the shipped one: the fork-starved arm's `boot`, then the
# main path `boot disk reap refresh`, then the listing `sweep` (a deliberate second site, ahead of
# `claims`), then `claims caches sweep gate l5_issue`, then the record block's `record`.
_tiled_order="$(printf '%s\n' "$_loop_nc" | grep -oE '^[[:space:]]*stg_mark [a-z0-9_]+' | awk '{print $2}' | tr '\n' ' ' | sed 's/ *$//')"
_tiled_want="boot boot disk disk reap refresh authority sweep claims caches sweep gate l5_issue record"
ck "the TILED marks appear in BODY ORDER (order is what makes the attribution right; every arm above grades only existence)" \
   "$(if [ "$_tiled_order" = "$_tiled_want" ]; then echo 0; else echo 1; fi)"
ck "  …order actually read: '${_tiled_order:- none}'" \
   "$(if [ -n "$_tiled_order" ]; then echo 0; else echo 1; fi)"
# ⛔ THE SEQUENCE ALONE IS NOT THE PROPERTY: A MARK CAN MOVE AND KEEP THE SEQUENCE (fresh-context review,
# P1 — measured). Inserting `stg_mark gate` IMMEDIATELY AFTER the per-PR `stg_mark sweep` leaves the name
# order byte-identical, so the arm above stays GREEN at 121/0 — while `gate` closes a ~0 interval and the
# whole fleet-placement / CI-queue / gate-vector block is charged to `l5_issue`, the very misattribution
# this PR exists to fix. So `gate` is pinned POSITIONALLY: it must sit AFTER the ceiling line that $LOG's
# own gate rationale names, i.e. after `floor_emergency`'s call site, which is the last thing the stage
# covers. (Inserting it before the per-PR sweep was already caught; this catches the other direction.)
# ⛔ THE SEQUENCE ALONE IS NOT THE PROPERTY: A MARK CAN MOVE AND KEEP THE SEQUENCE (fresh-context review,
# P1 — measured). Inserting `stg_mark gate` IMMEDIATELY AFTER the per-PR `stg_mark sweep` leaves the name
# order byte-identical, so the arm above stayed GREEN at 121/0 — while `gate` closed a ~0 interval and the
# whole fleet-placement / CI-queue / gate-vector / floor / funnel block was charged to `l5_issue`, the very
# misattribution this PR exists to fix. (Inserting it BEFORE the per-PR sweep is already caught by the
# per-PR-body arm.) So `gate` is pinned POSITIONALLY: the `floor_emergency` work it names must lie INSIDE
# its interval — i.e. between the per-PR `sweep` mark and the `gate` mark.
_sw_pr_line="$(grep -nE '^[[:space:]]*stg_mark sweep' <<<"$_loop_nc" | tail -1 | cut -d: -f1)"
_gate_line="$(grep -nE '^[[:space:]]*stg_mark gate([[:space:]]|$)' <<<"$_loop_nc" | head -1 | cut -d: -f1)"
_floor_in_gate="$(awk -v a="${_sw_pr_line:-0}" -v b="${_gate_line:-0}" '
  NR > a && NR < b && /floor_emergency/ && $0 !~ /^[[:space:]]*#/ { f=1 }
  END { exit !f }' <<<"$_loop_nc" && echo yes || echo no)"
ck "  …and \`gate\` covers the floor/gate work it names — a \`floor_emergency\` call lies between the per-PR \`sweep\` mark and \`gate\` (sweep@${_sw_pr_line:-?}, gate@${_gate_line:-?}: ${_floor_in_gate})" \
   "$(if [ "${_floor_in_gate:-no}" = "yes" ]; then echo 0; else echo 1; fi)"

# 9.1d-iii: NO NAP SITE MAY BE DROPPED, and the count is derived from the NAPS the loop performs.
# ⛔ THE COUNT IS SCOPED TO THE CONTROLLER'S OWN LOOP, NOT TO THE WHOLE FILE (agent-infra#3762,
# measured). `cascade_wait()` is a HELPER defined ABOVE `while true; do`, and its poll — `fork_free_sleep
# "$poll" || sleep "$poll"` — is a cadence measurement, not a cycle nap: it returns the moment a slot
# frees and has no `prev_wait` to carry. It was added by #3594, which took `_loop_n` from 4 to 5 while
# `_nap_n` stayed 3, so `_nap_n >= _loop_n - 1` became `3 >= 4` and this arm reddened ON MAIN — a false
# FAIL on a correct tree, for every branch off it, without grading a helper's poll as if it were a
# cycle nap. The region is derived, never assumed: a file that loses its `while true; do` FAILS here
# rather than silently counting every sleep in the file.
# ⛔ WHAT THIS ARM DOES **NOT** PROVE, MEASURED RATHER THAN ASSUMED (review cycle 10, P2-1). An earlier
# revision of this comment claimed "the slack of 1 is exactly the fork-starved site's TWO nap forms
# sharing ONE mark". That is FALSE. The body holds 4 nap lines and 3 marks, so `_nap_n >= _loop_n - 1`
# grants ONE FREE nap-line removal to ANY site: deleting the disk-held nap (`orch-loop.sh:4732`) or the
# fork-starved nap (`:4624`) leaves this arm GREEN — those two are caught only by the sibling arm
# asserting every `stg_nap_mark` samples `STG_WAIT_T0`; and moving the NORMAL-PATH nap (`:8877`,
# `sleep … & wait $!`, the else branch) above the loop reddens NOTHING in this suite at all (measured:
# 123 passed, 0 failed) — i.e. the controller could stop napping on its normal path and this arm would
# still certify it. Filed as agent-infra#3763. The slack is a property of the count, not of the
# fork-starved site, and a future author must not read the green as "no nap can be dropped".
# ⛔ AND THE POPULATION EXCLUDES ONE DECLARED, BOUNDED NON-NAP BLOCK (agent-infra#3584, measured).
# A `sleep` inside the controller loop is a nap only if the CYCLE waits on it. #3584 added an in-cycle
# RETRY BACKOFF — `sleep "$_rd"` inside the BACKGROUNDED refresh-pass subshell — which the cycle waits
# on for nothing, whose time sits inside the `refresh` stage rather than between cycles, and which
# could not carry a `stg_nap_mark` even in principle (that helper writes a shell variable, and a
# subshell's write dies with the subshell). The blanket rule charged it as a nap path and reddened a
# CORRECT tree: measured pristine `main` 123 passed/0 failed, this branch 122/1, with the arm reading
# `3 nap_mark sites for 5 sleep/fork_free_sleep lines`. Rather than widen the rule, `orch-loop.sh`
# DECLARES the block between `>>> BEGIN NOT-A-CYCLE-NAP` and `<<< END NOT-A-CYCLE-NAP`, and the arms
# below bound that declaration so it cannot become a place to hide a real nap:
#   (a) the pair appears EXACTLY ONCE inside the loop region (a lost END would otherwise exclude the
#       rest of the file, and a lost BEGIN silently re-counts the sleep — the main arm then reds);
#   (b) the block holds AT MOST ONE sleep line, so wrapping a second nap in it reds (b);
#   (c) the `_nap_n >= 3` floor above means a block drawn round the WHOLE loop empties `_nap_n` and
#       reds the main arm instead of vacuously passing it.
# This is the same doctrine as the `cascade_wait` scoping above: the rule is about CYCLE naps, and a
# declaration is what lets a text-derived population tell the two apart.
_loop_nap_region="$(printf '%s\n' "$_loop_tc" | awk '/^[[:space:]]*while true; do/{f=1} f')"
_nap_fence="$(awk '
  /^[[:space:]]*# >>> BEGIN NOT-A-CYCLE-NAP/ {f=1; next}
  /^[[:space:]]*# <<< END NOT-A-CYCLE-NAP/   {f=0; next}
  f' <<<"$_loop_nap_region")"
_nap_unfenced="$(awk '
  /^[[:space:]]*# >>> BEGIN NOT-A-CYCLE-NAP/ {f=1; next}
  /^[[:space:]]*# <<< END NOT-A-CYCLE-NAP/   {f=0; next}
  !f' <<<"$_loop_nap_region")"
# The fences are COMMENT lines, so the split above needs the comment-preserving view (`_loop_tc`, not
# `_loop_nc` — the same trap §9.1d-v records). The COUNTS then run on CODE-ONLY views (`_nap_code` for
# the fenced body, `_loop_code` for the population), so a word in a comment can neither become a nap
# nor hide one.
printf '%s\n' "$_nap_unfenced" > "$TMP/nap-region.txt"
printf '%s\n' "$_nap_fence" > "$TMP/nap-fenced.txt"
_nap_region="$(_strip_tc "$TMP/nap-region.txt")"
_nap_excl_body="$(_strip_tc "$TMP/nap-fenced.txt")"
# ⛔ THE COUNTS RUN ON A CODE-ONLY VIEW, AND THAT IS TWO FIXES IN ONE (fresh-context review, P1+P2,
# measured). First: `_strip_tc` removes only TRAILING comments, so a FULL-LINE comment survived into
# `_nap_excl_body`, falsifying the claim two lines above — adding the comment
# `# NB: the old shape was `if false; sleep 30 ; fi`` reddened a nap-free tree (127/1). Second, and
# worse: every counter was LINE-POSITION dependent, so a boundary or a nap could be hidden by
# prefixing ONE token. Measured — all four of these left `RESULT: 128 passed, 0 failed`:
#   `) ; sleep 300 ; (`   ·   `: ) ; command sleep 3 ; (`   ·   `true ) ; (` + `\sleep 300`
#   ·   `) ; command sleep 300 ; (` appended to the existing `done` line
# So the view is comment-free AND string-literal-free (the TRANSIENT echo messages carry `(attempt ...)`
# parens, which would otherwise read as openers), a nap is matched as a TOKEN ANYWHERE on a line (so
# `command sleep`, `\sleep` and `sleep$IFS` all count), and the CLOSER is proven by the PARSER rather
# than by a spelling: `f() { <body> }` fails `bash -n` on an unmatched `)`. Over-counting is the
# fail-closed direction; UNDER-counting is the bypass, so every pattern errs wide on purpose.
_nap_code="$(printf '%s\n' "$_nap_excl_body" | grep -vE '^[[:space:]]*#' | sed -E 's/"[^"]*"//g')"
_nap_closers=0
printf 'f() {\n%s\n}\n' "$_nap_excl_body" | bash -n 2>/dev/null || _nap_closers=1
_region_ok=1
[ -n "$_loop_nap_region" ] || _region_ok=0
_nap_n="$(grep -cE '^[[:space:]]*stg_nap_mark([[:space:]]|$)' <<<"$_nap_region")"
# ⛔ THE POPULATION COUNTER IS TOKEN-ANYWHERE TOO (fresh-context review, P1 — measured). `_loop_n`
# stayed anchored at the START of the line, so the one view that decides whether a nap is IN the
# population still missed a nap hidden behind a prefix token. Measured on this tree: inserting the
# single line `: ; sleep 300` inside `while true; do` (a real 300 s nap on the CYCLE path, no
# `stg_nap_mark`) left the suite at `RESULT: 128 passed, 0 failed`. The two fence counters above were
# fixed and this one — grading the same class, in the same arm — was not, so "every pattern errs wide
# on purpose" was false until this line changed.
# ⛔ CONTINUATIONS ARE JOINED INTO ONE LOGICAL LINE, NOT DROPPED (fresh-context review, P1 — measured).
# Dropping the lines that BEGIN with `||`/`&&` was this arm's first fix, and it re-created the very
# under-count it was added to close: a nap written as a two-line conditional whose PARENT is not a nap
# —
#     false \
#       || sleep 300
# — has its nap line dropped and its parent contributes no token, so the nap left the population and
# the suite stayed at `RESULT: 128 passed, 0 failed` (measured). The shipped fork-starved nap has the
# same two-line SHAPE but the opposite meaning (one logical nap, counted once), so NO line-shape rule
# can separate the two cases: the only sound reading is per LOGICAL line. Continuations are therefore
# JOINED before counting, and `grep -c` then gives 4 on this tree and 5 with the conditional nap above.
_loop_code="$(grep -vE '^[[:space:]]*#' <<<"$_nap_region" | sed -E 's/"[^"]*"//g' \
  | awk '{ while (sub(/\\[[:space:]]*$/, "")) { if ((getline n) <= 0) break; $0 = $0 " " n } print }')"
_loop_n="$(grep -cE '(^|[^[:alnum:]_])(fork_free_sleep|sleep)([^[:alnum:]_]|$)' <<<"$_loop_code")"
ck "every nap path calls stg_nap_mark (${_nap_n} nap_mark sites for ${_loop_n} sleep/fork_free_sleep lines inside the controller loop — a path without one loses prev_wait; loop region ${_region_ok})" \
   "$(if [ "$_region_ok" -eq 1 ] && [ "${_nap_n:-0}" -ge 3 ] && [ "${_nap_n:-0}" -ge "$(( ${_loop_n:-0} - 1 ))" ]; then echo 0; else echo 1; fi)"

# 9.1d-iii-b: THE NON-NAP DECLARATION IS BOUNDED, so it cannot be used to hide a nap. Every arm here
# reds if the declaration is widened, duplicated or lost — the three ways the exclusion above could
# become a hole instead of a fact about a subshell backoff.
# ⛔ AND IT MUST NOT SPAN THE SUBSHELL BOUNDARY (fresh-context review, P2 — measured). The first
# revision opened the fence BEFORE `if [ -n "$REFRESH_SH" ]; then`, so an outer-shell `sleep` inserted
# between the fence and `while :; do` sat on the CYCLE path, was excluded from the population, and left
# all arms GREEN — a real nap hidden by the exemption. So the structure is pinned, not just the counts:
# the fence contains NO subshell opener and NO closer (it is strictly INTERIOR to the subshell), and the
# nearest preceding code line is the opener itself. The pair is what makes "not a cycle nap" a
# statement about the code rather than a label.
# ⛔ A CLOSER IS ANY LINE THAT BEGINS WITH `)` — NOT TWO SPELLINGS OF IT (fresh-context review, P1,
# measured). The previous pair anchored on `)^$` and `)&$`, so a closer written `) ;` matched NEITHER,
# and `_nap_excl_sleeps` only counted lines that BEGIN with `sleep`, so a nap on the same line was
# invisible too. Measured: inserting the single line `          ) ; sleep 300 ; (` immediately before
# the END marker closes the subshell INSIDE the fence and runs a real 300 s nap on the CYCLE path —
# with every arm here byte-identically green (openers=0 closers=0, sleeps=1). That is the round-2 P2
# defect reintroduced through a spelling the counters could not see, so both are now spelling-agnostic:
# any line starting with `)` is a closer, and a nap counts anywhere it appears as a COMMAND on a line.
_nap_beg_n="$(grep -cE '^[[:space:]]*# >>> BEGIN NOT-A-CYCLE-NAP' <<<"$_loop_nap_region")"
_nap_end_n="$(grep -cE '^[[:space:]]*# <<< END NOT-A-CYCLE-NAP' <<<"$_loop_nap_region")"
_nap_excl_sleeps="$(grep -cE '(^|[^[:alnum:]_])(fork_free_sleep|sleep)([^[:alnum:]_]|$)' <<<"$_nap_code")"
_nap_excl_marks="$(grep -cE '(^|[^[:alnum:]_])stg_nap_mark([^[:alnum:]_]|$)' <<<"$_nap_code")"
_nap_excl_openers="$(grep -cE '(^|[^[:alnum:]_$(])\(' <<<"$_nap_code")"
_nap_excl_closers="$_nap_closers"
_nap_prev_code="$(awk '
  /^[[:space:]]*# >>> BEGIN NOT-A-CYCLE-NAP/ { exit }
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*#/ { next }
  { last=$0 }
  END { print last }' <<<"$_loop_nap_region")"
ck "the non-nap declaration is EXACTLY ONE bounded pair inside the loop (begin=${_nap_beg_n}, end=${_nap_end_n} — a lost end excludes the rest of the file)" \
   "$(if [ "${_nap_beg_n:-0}" -eq 1 ] && [ "${_nap_end_n:-0}" -eq 1 ]; then echo 0; else echo 1; fi)"
ck "  …and it holds AT MOST ONE sleep line, so a second nap cannot be parked in it (found ${_nap_excl_sleeps})" \
   "$(if [ "${_nap_excl_sleeps:-9}" -le 1 ]; then echo 0; else echo 1; fi)"
ck "  …and it holds NO stg_nap_mark, because a marked nap is not what it declares (found ${_nap_excl_marks})" \
   "$(if [ "${_nap_excl_marks:-9}" -eq 0 ]; then echo 0; else echo 1; fi)"
ck "  …and it spans NO subshell boundary — no opener and no closer inside it (openers=${_nap_excl_openers}, closers=${_nap_excl_closers})" \
   "$(if [ "${_nap_excl_openers:-9}" -eq 0 ] && [ "${_nap_excl_closers:-9}" -eq 0 ]; then echo 0; else echo 1; fi)"
ck "  …and the nearest code line BEFORE it opens that subshell, so the fence is interior to the backgrounded pass ('${_nap_prev_code}')" \
   "$(if [ "${_nap_prev_code:-x}" = x ]; then echo 1; elif [[ "${_nap_prev_code}" =~ ^[[:space:]]*\(([[:space:]]|$) ]]; then echo 0; else echo 1; fi)"

# 9.1g THE READER REFUSES A GLOB AS A STAGE NAME.
# ⛔ THESE ARMS PIN THE OBSERVABLE, NOT THE GUARD. The wanted name is validated AND used quoted, so the
# observable survives deletion of either; what they forbid is a future edit that drops the quoting and
# lets `*` match the first stage in the field.
# `cycle_stage_get` validates the WANTED name and then uses it as a `case` PATTERN. Without that guard a
# caller passing `*` matches the FIRST stage in the field and returns its value as if it were the one
# requested — a silent wrong answer, which is worse than a refusal because the whole point of the field
# is that its numbers can be trusted. ⛔ THAT GUARD HAD NO ARM AT ALL (fourth fresh-context review, P3 —
# measured: deleting it left the suite at 83/0 while `cycle_stage_get 'stages=boot:3' '*'` began
# answering `3` rc 0).
ck "a GLOB is refused as a stage name — '?' matches any one character and must not be a reading" \
   "$(if cycle_stage_get 'stages=boot:3' '?' >/dev/null 2>&1; then echo 1; else echo 0; fi)"
ck "  …and '*' — the one that would otherwise return the FIRST stage's value as the requested one" \
   "$(if cycle_stage_get 'stages=boot:3,sweep:9' '*' >/dev/null 2>&1; then echo 1; else echo 0; fi)"
ck "  …and a bracketed class ('[bs]oot', which the record sanitiser does NOT strip) is refused too" \
   "$(if cycle_stage_get 'stages=boot:3' '[bs]oot' >/dev/null 2>&1; then echo 1; else echo 0; fi)"
ck "  …while a real name beside those still reads (sweep=9)" \
   "$(if [ "$(cycle_stage_get 'stages=boot:3,sweep:9' sweep)" = "9" ]; then echo 0; else echo 1; fi)"

# 9.1h `stg_mark` SETTLES AN OPEN OVERLAY, so no overlay interval can span a tiled boundary.
# ⛔ THE CLAIM HAD NO ARM (fourth fresh-context review, P3 — measured: deleting the `stg_lvl_settle`
# from `stg_mark` left the suite at 83/0). It is unreachable in the SHIPPED arrangement today — every
# `stg_lvl_start` lives inside the sweep's pipeline subshell, so the parent's `STG_OPEN_LVL` is always
# empty when a `stg_mark` runs — which is exactly why it needs a DRIVEN arm: an unreachable guard with
# no arm is one deletion away from being an untested claim. Driven at top level, where it IS reachable.
STG_LVL_TMP="$TMP/lvlq-mark"; : >"$STG_LVL_TMP"
STG_OPEN_LVL=""; STG_OPEN_T0=0
stg_cycle_reset
stg_lvl_start l2_merge || :
sleep 1.1
stg_mark gate                      # a tiled mark must CLOSE the open overlay first
_open_after_mark="${STG_OPEN_LVL-UNSET}"
sleep 1.1                          # a SECOND tiled interval with NO overlay opened: it must accrue none
stg_mark l5_issue
# ⛔ `stg_field` is called AT TOP LEVEL, never inside `$( … )`: it writes its result into a NAMED
# variable, and inside a command substitution that assignment dies with the subshell.
_mf=""
stg_field _mf || _mf=""
_mark_l2="$(cycle_stage_get "stages=$_mf" l2_merge 2>/dev/null || echo ABSENT)"
ck "stg_mark SETTLES an open overlay into its own level — it cannot be credited to the tiled stage (l2_merge='$_mark_l2')" \
   "$(if [ "${_mark_l2:-0}" -ge 1 ] 2>/dev/null && [ "${_mark_l2:-0}" -le 5 ] 2>/dev/null; then echo 0; else echo 1; fi)"
# ⛔ THE CLAIM IS ABOUT THE BOUNDARY, NOT ABOUT WHETHER THE TILED STAGE ALSO SEES THE TIME. An overlay
# is a BREAKDOWN of the tiled stage it ran inside, so both legitimately count it (`sum(l1..l4) <=
# sweep`). What must NOT happen is an overlay interval SPANNING the boundary — which is what an unclosed
# `STG_OPEN_LVL` after a mark would mean. Asserted two ways: the level is closed by the mark, and a
# LATER tiled interval with no overlay opened accrues nothing to it.
ck "  …so the mark CLOSED the overlay: no level is left open after it (STG_OPEN_LVL='${_open_after_mark}')" \
   "$(if [ "$_open_after_mark" = "" ]; then echo 0; else echo 1; fi)"
ck "  …and a LATER tiled interval (no overlay opened) adds NOTHING to the level — it cannot span the boundary (l2_merge='$_mark_l2' over ~2.2 s of body)" \
   "$(if [ "${_mark_l2:-0}" -ge 1 ] 2>/dev/null && [ "${_mark_l2:-0}" -le 3 ] 2>/dev/null; then echo 0; else echo 1; fi)"
STG_LVL_TMP=""

# 9.1d-iv: THE QUEUE MUST ACTUALLY BE WIRED TO A REAL PATH BEFORE THE SWEEP.
# ⛔ §9.1/§9.1b SET `STG_LVL_TMP` THEMSELVES, so they grade the MECHANISM and cannot see the two lines
# that make it reachable in production. Deleting `STG_LVL_TMP="$O/state/.stg-lvl"` and its truncate left
# the suite at 93/0 while (measured, driving a real pipeline) `l2_merge:1` became `l2_merge:ns` on every
# cycle — the whole cascade half of the field silently dead, which is exactly the P0 §9.1 exists to
# prevent. The assignment is required on stripped code, and it must precede the sweep's pipeline.
_q_wire="$(printf '%s\n' "$_loop_nc" | grep -nE '^[[:space:]]*STG_LVL_TMP="\$O/state/\.stg-lvl"' | head -1 | cut -d: -f1)"
_q_trunc="$(printf '%s\n' "$_loop_nc" | grep -nE '^[[:space:]]*: >"\$STG_LVL_TMP"' | head -1 | cut -d: -f1)"
_q_sweep="$(printf '%s\n' "$_loop_nc" | grep -nE '^[[:space:]]*printf .*\|$' | head -1 | cut -d: -f1)"
ck "the overlay queue is WIRED to a real path before the sweep (assign=${_q_wire:- MISSING}, truncate=${_q_trunc:- MISSING}, sweep=${_q_sweep:-?})" \
   "$(if [ -n "$_q_wire" ] && [ -n "$_q_trunc" ] && [ -n "$_q_sweep" ] && [ "$_q_wire" -lt "$_q_sweep" ] && [ "$_q_trunc" -lt "$_q_sweep" ]; then echo 0; else echo 1; fi)"
ck "  …and a failure to CREATE it is flagged, not merely ignored (STG_LVL_QOK-style, or the path cleared)" \
   "$(grep -qE ': >"\$STG_LVL_TMP" 2>/dev/null \|\| .*STG_LVL_TMP=""' <<<"$_loop_nc" && echo 0 || echo 1)"

# 9.1d-vi: THE CASCADE LEVELS MUST BE OPENED WHERE THE WORK THEY NAME HAPPENS — not merely somewhere.
# ⛔ OPENING A LEVEL ABOVE A `case` CHARGES EVERY BRANCH OF IT, and that was MEASURED in the shipped
# arrangement (fresh-context review, P2): `l3_fix` opened above the conflict case, so a `PENDING` PR — the
# majority state on a rail repo — had its landing-side work reported as FIXING while `l2_merge` read `ns`
# for the whole cycle. The suite was green at 101/0. The same class was already fixed once at
# `[redfix:end]`, which is why attribution ORDER is now graded and not just existence.
_cc_region="$(awk '
  /# \[conflict-case:begin\]/ { inb=1; next }
  /# \[conflict-case:end\]/   { inb=0 }
  inb && /^[[:space:]]*MSTAT=/ { m=NR }
  inb && /^[[:space:]]*stg_lvl_start l3_fix([[:space:]]|$)/ { if (!l3) l3=NR }
  END { printf "%d %d", m+0, l3+0 }' <<<"$_loop_tc")"
set -- $_cc_region; _cc_mstat="${1:-0}"; _cc_l3="${2:-0}"
ck "the conflict case opens level 3 INSIDE the CONFLICTING branch, not above the case (MSTAT line ${_cc_mstat}, l3_fix line ${_cc_l3})" \
   "$(if [ "${_cc_mstat:-0}" -gt 0 ] && [ "${_cc_l3:-0}" -gt "${_cc_mstat}" ]; then echo 0; else echo 1; fi)"
# ⛔ AND EVERY `case` ARM THAT LANDS A PR OPENS LEVEL 2 ITSELF. The PENDING arm does landing-side work
# and opened no level, so it inherited the previous arm's — measured.
# ⛔ EVERY `case` ARM THAT DOES A LEVEL'S WORK MUST OPEN THAT LEVEL ITSELF — otherwise it inherits the
# previous arm's open, so its cost is credited to a level it is not doing. Measured: deleting the GREEN
# arm's own `l2_merge` open (the next open is PENDING's) stayed GREEN at 104/0, because §9.3 only needs a
# site SOMEWHERE for each level. One row per (arm, level) pair the shipped code is supposed to have.
_armlvl_bad=""
for _pair in 'GREEN)|l2_merge' 'PENDING:[*])|l2_merge' 'FAILED:[*])|l3_fix'; do
  _m="${_pair%%|*}"; _lv="${_pair##*|}"
  # the arm marker must be the WHOLE case label on its own line — `      GREEN)` — not the
  # classification one-liner `      GREEN)   _cl=GREEN ;; PENDING:*) …` far above it.
  awk -v m="$_m" -v lv="$_lv" '
    $0 ~ ("^[[:space:]]*" m "[[:space:]]*$") { inb=1; next }
    inb && /^[[:space:]]*(GREEN\)|PENDING:\*\)|FAILED:\*\)|\*\))/ { inb=0 }
    inb && $0 ~ ("^[[:space:]]*stg_lvl_start " lv "([[:space:]]|$)") { f=1 }
    END { exit !f }' <<<"$_loop_tc" || _armlvl_bad="$_armlvl_bad $_m/$_lv"
done
ck "each landing/fixing arm opens ITS OWN level (GREEN->l2_merge, PENDING->l2_merge, FAILED->l3_fix)${_armlvl_bad:+ — missing:$_armlvl_bad}" \
   "$(if [ -z "$_armlvl_bad" ]; then echo 0; else echo 1; fi)"

# 9.1d-v: THE PER-PR CASCADE SITES ARE PINNED BY REGION, NOT JUST BY EXISTENCE.
# §9.3 requires a `stg_lvl_start l<N>_` call site SOMEWHERE for each declared level, so it cannot see a
# site deleted from the region that owns it. Measured: deleting the red-fixer block's `l3_fix` open left
# the suite at 95/0, and the loss is real — with nothing open, the whole block's interval is attributed
# to no level at all. The regions are delimited by the markers the extracted suites already rely on.
# ⛔ `$_loop_tc`, NOT `$_loop_nc`: the markers ARE comment lines, and `_loop_nc` has stripped them.
# Here-strings, not a `printf | awk` pipe — the suite's own header forbids a piped quiet consumer and
# this payload is ~200 KB.
_redfix_l3="$(awk '
  /# \[redfix:begin\]/ { inb=1; next }
  /# \[redfix:end\]/   { inb=0 }
  inb && /^[[:space:]]*stg_lvl_start l3_fix([[:space:]]|$)/ { f=1 }
  END { exit !f }' <<<"$_loop_tc" && echo 0 || echo 1)"
ck "the RED-FIXER block opens cascade level 3 inside its own region ([redfix:begin]..[redfix:end])" "$_redfix_l3"
_redfix_close="$(awk '
  /# \[redfix:end\]/ { seen=1 }
  seen && /^[[:space:]]*stg_lvl_settle([[:space:]]|$)/ { f=1 }
  seen && /^[[:space:]]*V="\$\(gh pr checks/ { exit }
  END { exit !f }' <<<"$_loop_tc" && echo 0 || echo 1)"
ck "  …and CLOSES it before the per-PR check classifier, so classification is not charged to a cascade level" "$_redfix_close"

# 9.1d-vii: THE SWEEP'S PAGINATED PR LISTING IS CHARGED TO `sweep`, NOT TO `authority` (P1 — measured).
# `stg_mark` closes the current interval INTO THE STAGE IT NAMES, so an `authority` mark placed AFTER the
# listing booked the whole paginated `gh api …/pulls?state=open` sweep (plus `open_pr_count` and the
# branch-protection read) to `authority` — while the doc text shipped beside this change listed
# `authority` among the "genuinely sub-second stages" (that sentence is THIS PR's own, not `main`'s; it
# has since been corrected). #2028, this
# field's own root cause, is rate-limited `gh` calls pinning command substitutions open for 40+ minutes;
# booking a slow LISTING to a name that describes no listing hides exactly the minutes an operator
# wants. The marks must bracket the block, and OUTSIDE its extractable `[BEGIN|END]` markers so
# `sweep-quota.test.sh` can still drive the block standalone.
_ls_b="$(grep -nE '^[[:space:]]*# BEGIN sweep-listing' <<<"$_loop_tc" | head -1 | cut -d: -f1)"
_ls_e="$(grep -nE '^[[:space:]]*# END sweep-listing' <<<"$_loop_tc" | head -1 | cut -d: -f1)"
_ls_pre="$(printf '%s\n' "$_loop_tc" | awk -v b="${_ls_b:-0}" 'NR<b && /^[[:space:]]*stg_mark /{m=$2} END{print m}')"
_ls_post="$(printf '%s\n' "$_loop_tc" | awk -v e="${_ls_e:-0}" 'NR>e && /^[[:space:]]*stg_mark /{print $2; exit}')"
ck "the sweep's PR LISTING is charged to 'sweep', not 'authority' (last mark before BEGIN='${_ls_pre:- MISSING}', first mark after END='${_ls_post:- MISSING}')" \
   "$(if [ "${_ls_pre:-}" = "authority" ] && [ "${_ls_post:-}" = "sweep" ]; then echo 0; else echo 1; fi)"

# 9.1d-viii: A TYPO'D `stg_mark` MUST NOT SWALLOW THE INTERVAL (P3 — measured).
# `stg_add` rejected only non-`[A-Za-z0-9_]` characters, so `stg_mark swep` wrote `STG_V_swep` — a
# variable the emitter walks NEITHER as a stage nor as `ns` — and 1.2 s of wall time left the tiled
# partition with no `ns` anywhere to signal it (measured: `sweep:0`, `STG_V_swep=1201777` µs never
# emitted). Driven against the SHIPPED clock: the span must land on the next VALID mark.
stg_cycle_reset
stg_mark boot
sleep 1.2
stg_mark swep                 # the typo: must NOT close the interval
stg_mark sweep
stg_field _typo_f
_t_boot="$(cycle_stage_get "stages=$_typo_f" boot 2>/dev/null || echo X)"
_t_sweep="$(cycle_stage_get "stages=$_typo_f" sweep 2>/dev/null || echo X)"
ck "a typo'd stg_mark does NOT swallow the interval — the span lands on the next VALID mark (boot='$_t_boot', sweep='$_t_sweep') and no 'swep' token is emitted" \
   "$(if [ "${_t_boot:-X}" = "0" ] && [ "${_t_sweep:-0}" -ge 1 ] 2>/dev/null && [ "${_t_sweep:-0}" -le 5 ] 2>/dev/null && ! qF 'swep:' "$_typo_f"; then echo 0; else echo 1; fi)"
# And the LEVEL half: an unknown level name must be REFUSED, not queued into a variable nothing reads.
STG_LVL_TMP="$TMP/lvlq-typo"; : >"$STG_LVL_TMP"; STG_OPEN_LVL=""; STG_OPEN_T0=0
stg_lvl_start l2_merg || :    # the typo
stg_lvl_settle || :
_lvq="$(wc -l < "$STG_LVL_TMP" 2>/dev/null | tr -d ' ')"
ck "  …and an UNKNOWN cascade level is refused, so nothing is queued the emitter never walks (queue lines='${_lvq:-?}')" \
   "$(if [ "${_lvq:-1}" = "0" ]; then echo 0; else echo 1; fi)"
STG_LVL_TMP=""; STG_OPEN_LVL=""; STG_OPEN_T0=0

# 9.1d-ix: LEVEL 3 MUST BE CLOSED AT THE CLASSIFICATION, NOT LEFT OPEN FROM THE RED-TREE ARM.
# ⛔ THE FIRST VERSION OF THIS ARM WAS A FALSE PASS AND IS REPLACED (fresh-context review of the fix
# round, P1 — measured end-to-end). It only demanded "no `stg_lvl_start l3_fix` between `_rgs=` and
# `_fix_eligible=1`", so DELETING the open there left it green — and the emitted field was
# BYTE-IDENTICAL (`l3_fix:1, l4_review:ns`), because the `FAILED:*` arm had ALREADY opened level 3 fifty
# lines above and `stg_lvl_start` only settles at the next open. The property that actually has to hold
# is that level 3 is SETTLED after the remedy is classified, so the review-side branches
# (`review_disp_decide`, `review_athead_bump`, `park_ctrl`) cannot inherit the red-tree arm's open: a
# NEEDS-REVIEW PR at AT-HEAD — the documented steady state for a PR nothing is fixing — must not report
# "fixing". Both halves are graded: the settle present, and no l3 open above the fix-eligibility decision.
_nf_l3_before="$(awk '
  /_rgs="\$\(review_gate_state/ { inb=1; next }
  inb && /_fix_eligible=1/ { fe=1 }
  inb && /^[[:space:]]*stg_lvl_start l3_fix/ && !fe { bad=1 }
  END { print (bad?"yes":"no") }' <<<"$_loop_tc")"
ck "the NEEDS-FIX classifier does NOT open level 3 above the fix-eligibility decision (got '${_nf_l3_before:-?}')" \
   "$(if [ "${_nf_l3_before:-yes}" = "no" ]; then echo 0; else echo 1; fi)"
# ⛔ AND EVERY FIX-SIDE ACTUATOR OUTSIDE THAT CLASSIFIER OPENS LEVEL 3 ITSELF (fresh-context review,
# P2 — measured). Deleting the `stg_lvl_start l3_fix` that used to sit at the top of the `FAILED:*` arm
# left the suite at 112/0, which is the same vacuity shape §9.1d-v already documents: §9.3 needs a site
# SOMEWHERE. Two actuators were then unattributed: the `elif [ -n "$CI_RED" ]` arm (which dispatches the
# fixer, or reports the fix-lane capacity that refused it) and the python-ci-gate RERUN block (a second
# actuator that runs after the arm chain). Each must open its own level.
_cired_open="$(awk '
  /elif \[ -n "\$CI_RED" \]; then/ { inb=1; next }
  inb && /^[[:space:]]*stg_lvl_start l3_fix/ { ok=1 }
  inb && /# ⛔ THE RERUN IS A SECOND ACTUATOR/ { exit }
  END { print (ok?"opened":"MISSING") }' <<<"$_loop_tc")"
ck "the CI-RED fixer arm opens level 3 itself, so a CI repair is not attributed to no level (got '${_cired_open:-?}')" \
   "$(if [ "${_cired_open:-MISSING}" = "opened" ]; then echo 0; else echo 1; fi)"
_rerun_open="$(awk '
  /grep -q python-ci-gate <<<"\$V"/ { inb=1; next }
  inb && /^[[:space:]]*stg_lvl_start l3_fix/ { ok=1 }
  inb && /RID="\$\(gh pr checks/ { exit }
  END { print (ok?"opened":"MISSING") }' <<<"$_loop_tc")"
ck "  …and the python-ci-gate RERUN actuator opens level 3 itself (it runs after the arm chain, so it inherits nothing) (got '${_rerun_open:-?}')" \
   "$(if [ "${_rerun_open:-MISSING}" = "opened" ]; then echo 0; else echo 1; fi)"
# ⛔ AND THE `FAILED:*` ARM MUST NOT OPEN IT ABOVE THE REMEDY CHOICE — that open is what leaked into the
# no-arm and rerun paths and booked a `gh pr checks` lookup and a `gh run rerun` to `l3_fix`.
_failed_open="$(awk '
  /^[[:space:]]*FAILED:\*\)/ { inb=1; next }
  inb && /if \[ "\$_gate_hit" = "1" \]; then/ { decided=1 }
  inb && /^[[:space:]]*stg_lvl_start l3_fix/ && !decided { bad=1 }
  END { print (bad?"above":"ok") }' <<<"$_loop_tc")"
ck "  …and NOT at the top of the FAILED arm, where it leaked across the no-arm and rerun paths (got '${_failed_open:-?}')" \
   "$(if [ "${_failed_open:-above}" = "ok" ]; then echo 0; else echo 1; fi)"
_nf_l3_settle="$(awk '
  /_rgs="\$\(review_gate_state/ { inb=1; next }
  inb && /^[[:space:]]*stg_lvl_settle/ && !seen { settle=1 }
  inb && /review_disp_decide "\$PR"/ { seen=1; if (settle) ok=1; exit }
  END { print (ok?"closed":"OPEN") }' <<<"$_loop_tc")"
ck "  …and the red-tree arm's level 3 is SETTLED before the review-side branches, so a NEEDS-REVIEW PR at AT-HEAD does not read 'fixing' (got '${_nf_l3_settle:-?}')" \
   "$(if [ "${_nf_l3_settle:-OPEN}" = "closed" ]; then echo 0; else echo 1; fi)"

# 9.1d-x: `stg_mark` REFUSES AN OVERLAY NAME (P3 — verified). `stg_is_registered` accepted `l4_review`, so
# `stg_mark l4_review` accumulated a TILED span into the overlay's variable and broke the documented
# containment `sum(l1..l4) <= sweep` (an overlay can exceed the sweep it sits inside), silently, because
# the name was registered. Driven: the overlay must stay untouched.
stg_cycle_reset
STG_LVL_TMP=""
stg_mark boot
stg_mark l4_review            # wrong function, registered name: must be REFUSED
stg_field _ov_f
_ov_v="$(cycle_stage_get "stages=$_ov_f" l4_review 2>/dev/null || echo X)"
ck "a stg_mark naming an OVERLAY is refused, so no tiled span can be added to a cascade level (l4_review='${_ov_v:-?}')" \
   "$(if [ "${_ov_v:-x}" = "ns" ]; then echo 0; else echo 1; fi)"
# ⛔ EVERY ONE OF THE THREE REVIEW-CLASSIFIER FIX-SIDE BRANCHES MUST OPEN LEVEL 3 ITSELF (fresh-context
# review, P2 — measured). The arms below `_armlvl_bad` cover the `case` arms and the actuators OUTSIDE
# the classifier, but NOT these three — and deleting each of them left the suite at 115/0. With the
# `stg_lvl_settle` before `review_disp_decide` in place, a deleted open here closes level 3 for the whole
# classifier region, so a cycle that spawned three fixers reports `l3_fix:ns` while its seconds land in
# `sweep` as "no cascade level was the active work" — the field's headline question answered wrongly,
# with every check green. Same vacuity shape §9.1d-v documents catching twice.
_cls_l3="$(awk '
  /if \[ "\$_fix_eligible" = "1" \]; then/ { sec=1; next }
  /elif \[ "\$NF" -ge/ { sec=2; next }
  /elif \[ "\$_rgs" = "NEEDS-FIX" \]; then/ { sec=3; next }
  /elif \[ -z / { sec=0; next }
  /^[[:space:]]*stg_lvl_start l3_fix/ && sec>0 { seen[sec]=1 }
  END { for (i=1;i<=3;i++) if (!seen[i]) miss = miss " " i; print (miss=="" ? "all" : "MISSING:" miss) }' <<<"$_loop_tc")"
ck "all THREE review-classifier fix-side branches open level 3 themselves (spawn/cap-park/capacity-wait -> '${_cls_l3:-?}')" \
   "$(if [ "${_cls_l3:-}" = "all" ]; then echo 0; else echo 1; fi)"
# ⛔ AND THE PER-PR-BODY `sweep` MARK IS ITS OWN ARM (fresh-context review, P2 — measured). `sweep` is
# marked TWICE (the listing, then the per-PR body) and the "every TILED stage has a call site" arm is
# satisfied by the listing alone — so deleting the second left the suite at 115/0. With it gone, the
# interval from `caches` to `gate` (the ownership scan, the selection order and the ENTIRE PR sweep —
# the largest span of any cycle, and where the 161-minute cycles live) is booked to `gate`: a record
# reading `sweep:2, gate:5760`, i.e. exactly the P1 this PR fixed, reintroducible by one deleted line.
_sp_body="$(awk '
  /^[[:space:]]*stg_mark caches/ { c=NR }
  /^[[:space:]]*stg_mark gate/   { if (!g) g=NR }
  /^[[:space:]]*stg_mark sweep/ && c && NR>c && (g==0 || NR<g) { f=1 }
  END { print (f?"present":"MISSING") }' <<<"$_loop_tc")"
ck "the PER-PR-BODY sweep mark exists between 'caches' and 'gate', so the PR sweep is not booked to gate ('${_sp_body:-?}')" \
   "$(if [ "${_sp_body:-}" = "present" ]; then echo 0; else echo 1; fi)"
# ⛔ AND THE TOP-OF-ROW SETTLE IS GRADED (fresh-context review, P3 — driven). Removing it ADDS the next
# row's `HEAD_N=$(gh pr view …)` to the PREVIOUS row's level (measured 1001 ms vs 2004 ms over two rows).
_row_settle="$(awk '
  /^[[:space:]]*\[ -z "\$\{PR:-\}" \] && continue/ { if (prev ~ /^[[:space:]]*stg_lvl_settle/) ok=1 }
  { prev=$0 }
  END { print (ok?"present":"MISSING") }' <<<"$_loop_tc")"
ck "the TOP-OF-ROW stg_lvl_settle is present, so a previous row's level cannot adopt the next row's HEAD read ('${_row_settle:-?}')" \
   "$(if [ "${_row_settle:-}" = "present" ]; then echo 0; else echo 1; fi)"

# 9.1e `stg_field` FOLDS BEFORE IT EMITS — driven, not grepped.
# The post-`done` fold is not the last word: an overlay interval that closes at TOP level afterwards is
# still queued, and the field must report it rather than the value from one fold ago. Deleting the fold
# inside `stg_field` left the suite at 76/0 before this arm.
STG_LVL_TMP="$TMP/lvlq-field"; : >"$STG_LVL_TMP"
STG_OPEN_LVL=""; STG_OPEN_T0=0
stg_cycle_reset
stg_lvl_fold || :                       # the post-sweep fold: queue empty
stg_lvl_start l2_merge || :              # a TOP-LEVEL interval closing after that fold
sleep 1.1
stg_lvl_settle || :
_queued_before="${STG_V_l2_merge:-0}"
stg_field _qfield                        # NO explicit fold — stg_field must do it
_qv="$(cycle_stage_get "stages=$_qfield" l2_merge 2>/dev/null || echo ABSENT)"
# ⛔ A RANGE, NOT AN EQUALITY: values are WHOLE SECONDS, so a scheduling stall on a loaded box pushes a
# 1.1 s span to `2` and an exact `= "1"` reddens a required check for a reason that is not the change.
ck "an overlay closed AFTER the post-sweep fold still reaches the field (queued=${_queued_before} us, l2_merge='$_qv')" \
   "$(if [ "${_queued_before:-1}" -eq 0 ] && [ "${_qv:-0}" -ge 1 ] 2>/dev/null && [ "${_qv:-0}" -le 5 ] 2>/dev/null; then echo 0; else echo 1; fi)"
STG_LVL_TMP=""

# 9.1f THE CLOCK IS MONOTONIC — driven. `EPOCHREALTIME` is a WALL clock, so an ntp step or a VM resume
# can move it BACKWARDS, and a negative interval is indistinguishable in a record from a stage that
# never ran. The clamp is the whole protection; removing it left the suite at 76/0 before this arm.
_mono_hi=$(( ${STG_LAST_US:-0} + 60000000 ))
STG_LAST_US="$_mono_hi"
_m1=0; stg_now_us_vars _m1 || _m1=-1
ck "a BACKWARDS clock step never yields a value below the last one (last=${_mono_hi} us, got ${_m1} us)" \
   "$(if [ "${_m1:-0}" -ge "${_mono_hi}" ]; then echo 0; else echo 1; fi)"
_el=0; stg_now_us_vars _el || _el=-1
_mono_hi=$(( _el + 5000000 ))
STG_LAST_US="$_mono_hi"
_m2=0; stg_now_us_vars _m2 || _m2=-1
ck "  …and the clamp holds when the stored high-water mark is AHEAD of the wall clock (floor=${_mono_hi} us, got ${_m2} us)" \
   "$(if [ "${_m2:-0}" -ge "${_mono_hi}" ]; then echo 0; else echo 1; fi)"
STG_LAST_US=0

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
_loopcode="$(printf '%s\n' "$_loop_tc" | grep -vE '^[[:space:]]*#')"
# ⛔ ANCHORED AT COMMAND POSITION, LIKE THE TILED ARM ABOVE (fresh-context review, P2 — measured).
# `qF "stg_lvl_start $_lvl"` was a bare SUBSTRING match over the whole stripped file, so deleting the real
# call and spelling it inside any other code line (`: stg_lvl_start l4_review`) kept the arm GREEN at
# 101/0 — while `l4_review` then reads `ns` for ever. This is the arm guarding this PR's own P0 fix.
for _lvl in $STG_REGISTRY_LVL; do
  ck "cascade level '$_lvl' has an ANCHORED stg_lvl_start call site in the shipped loop (not just a registry entry)" \
     "$(if grep -qE "^[[:space:]]*stg_lvl_start $_lvl([[:space:]]|\$|;|\|)" <<<"$_loopcode"; then echo 0; else echo 1; fi)"
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

# 9.5 `record` MUST BE CLOSED AFTER THE PREPARATION, NOT BEFORE IT — asserted by VALUE, not by order.
# ⛔ THE PREVIOUS VERSION OF THIS ARM LOCKED IN THE DEFECT (fourth fresh-context review, P0): it
# asserted `stg_mark record` came BEFORE the `ids=`/`selected=` preparation, which is the arrangement
# that makes `record` close a ~0 µs sliver, opens an interval nothing closes, and DROPS the
# preparation's fork time entirely (strictly worse than attributing it to `l5_issue`). It was green on
# the broken tree and RED on the fix — an arm that fails the correction is worse than no arm.
# `stg_mark <stage>` closes the open interval INTO <stage>, so the correct arrangement is exactly:
#   reset -> mark l5_issue -> preparation (1.2 s) -> mark record -> stg_field
# which must emit `record >= 1`. The broken arrangement (mark record before the prep) emits 0 and
# loses the 1.2 s from the tiled partition altogether. Driving the SHIPPED clock proves the value.
stg_cycle_reset
stg_mark l5_issue
sleep 1.2                     # stand in for the tr/sed/cut/drain_stall_label preparation
stg_mark record
stg_field STG_FIELD
get "$STG_FIELD" record >/dev/null 2>&1 || true
_rec_v="$(get "$STG_FIELD" record)"
ck "the clock's own semantics: a 1.2 s span between marks is closed INTO the later stage (record=${_rec_v}) — the property the shipped placement relies on" \
   "$(if [ "${_rec_v:-0}" != "ns" ] && [ "${_rec_v:-0}" -ge 1 ] 2>/dev/null; then echo 0; else echo 1; fi)"
# …and structurally: the shipped closing mark must sit adjacent to the emit it precedes.
# ⛔ AND IT MUST SIT AFTER THE PREPARATION IT NAMES, NOT MERELY BEFORE `stg_field` (fresh-context review,
# P2 — measured). Moving BOTH shipped lines (`stg_mark record` and `stg_field STG_FIELD`) up above the
# `if [ "${CYCREC:-0}" = "1" ]` preparation kept order, kept adjacency and kept the call count, so the
# suite stayed GREEN at 121/0 — while `record` closed the `l5_issue`->`record` sliver and the
# `tr`/`sed`/`cut` preparation ran AFTER the last tiled mark, i.e. charged to NO stage at all. That is the
# P0 shape the comment above says was fixed, so the position is now pinned against the preparation itself.
_rec_pos="$(grep -nE '^[[:space:]]*stg_mark record([[:space:]]|$)' <<<"$_loop_nc" | head -1 | cut -d: -f1)"
_prep_pos="$(grep -nE '_cr_ids="\$\(tr' <<<"$_loop_nc" | head -1 | cut -d: -f1)"
ck "  …and AFTER the ids=/selected= preparation it measures (record@${_rec_pos:-?}, prep@${_prep_pos:-?})" \
   "$(if [ -n "${_rec_pos:-}" ] && [ -n "${_prep_pos:-}" ] && [ "$_rec_pos" -gt "$_prep_pos" ]; then echo 0; else echo 1; fi)"
ck "the shipped 'stg_mark record' is immediately before 'stg_field' (the only placement that closes the prep)" \
   "$(if printf '%s\n' "$_loop_nc" | awk 'prev ~ /^[[:space:]]*stg_mark record[[:space:]]*$/ && $0 ~ /^[[:space:]]*stg_field/ {found=1} {prev=$0} END {exit !found}'; then echo 0; else echo 1; fi)"

echo
# 9.1i THE FORK-STARVED RECORD'S `start=` AND `end=` MUST BE THE SAME TOKEN.
# The doc sentence that the starved arm can only be EQUAL or LONGER rests entirely on `end - start = 0`,
# i.e. on BOTH fields being that ONE token. ⛔ NOTHING GRADED IT: `end="$(date +%s)"` at that site left
# this suite GREEN at this head (verified), and it would ALSO put a fork on the agent-infra#2293 path.
# Derived, not spelled: the two expansions are pulled from the starved record site and compared.
_starved_rec="$(printf '%s\n' "$_loop_nc" | awk '/FORK_STARVED:-0.*= "1"/{f=1} f && /^[[:space:]]*start=/{print; exit}')"
_st_tok="$(printf '%s' "$_starved_rec" | sed -n 's/.*start="\${*\([A-Za-z0-9_]*\):-0}.*/\1/p')"
_en_tok="$(printf '%s' "$_starved_rec" | sed -n 's/.*end="\${*\([A-Za-z0-9_]*\):-0}.*/\1/p')"
ck "the fork-starved record writes start= and end= from the SAME token (got '${_st_tok:-none}' / '${_en_tok:-none}') — 'end - start = 0' is the docs' whole basis" \
   "$(if [ -n "$_st_tok" ] && [ "$_st_tok" = "$_en_tok" ]; then echo 0; else echo 1; fi)"

# 9.1j THE FORK-STARVED ARM'S RECORD WRITE IS FORK-FREE.
# §6 scans only the extracted clock block, so `cycle="$(printf …)"` inside the starved record write —
# the ONE path where a `$( )` TERMINATES bash (agent-infra#2293), and the path this change adds its
# `stages=` line to — left the suite GREEN at this head (verified). The scan is the RECORD-WRITE
# STATEMENT: from `cycle_record_write` through the last continuation line, which INCLUDES the
# `|| printf '…could not be recorded…'` failure branch — the branch that runs precisely when the starved
# record CANNOT be written, and where a fork is equally fatal. ⛔ An earlier version of this arm stopped
# at `stages=` and therefore left that branch ungraded (`$(date +%s)` added there stayed 97/0, verified).
# It is still not the whole arm BODY: the body's inline comments and printf MESSAGES name `$( )`, `date`
# and backticks to explain the ban, and matching inside prose is the vacuating shape §6 already stripped.
# ⛔ SPACES INSIDE THE ACTION BRACES, AND THAT IS NOT COSMETIC (fresh-context review, P2 — measured).
# `{r=1}` is read by this host's #1484/#709 working-tree-discard guard as a SCRIPT PATH (it carries a `/`
# and a brace-expansion shape), so `bash cycle-stages.test.sh` was REFUSED entirely — the guard's own
# message: "the body … cannot be fully read — "/cycle_record_write/{r=1}" is invoked as a script". A suite
# that cannot be run from a lane's worktree is exactly the state where "the cheapest way out is to claim
# it is green without running it", which is the failure this file exists to prevent. `{ r=1 }` is the
# same awk program and is not path-shaped.
_starved_body="$(printf '%s\n' "$_loop_nc" | awk '/FORK_STARVED:-0.*= "1"/ { f=1 } f && /cycle_record_write/ { r=1 } r { print; if ($0 !~ /\\$/) exit }' | sed 's/\$((//g')"
_sb_n="$(printf '%s\n' "$_starved_body" | grep -c . || true)"
ck "no command substitution in the FORK-STARVED arm's record write (${_sb_n:-0} lines scanned)" \
   "$(if [ -n "$_starved_body" ] && ! qF '$(' "$_starved_body"; then echo 0; else echo 1; fi)"
ck "  …nor a backtick or a 'date' fork in it" \
   "$(if [ -n "$_starved_body" ] && ! qF '`' "$_starved_body" && ! qF 'date ' "$_starved_body"; then echo 0; else echo 1; fi)"

# 9.1k A QUEUED INTERVAL MUST NOT SURVIVE INTO THE NEXT CYCLE.
# `stg_cycle_reset` truncates `$STG_LVL_TMP` so an interval queued AFTER the last fold cannot be added
# to the NEXT cycle's level — that would be a level reporting time it did not spend, the one defect
# class this field exists to end. ⛔ Deleting just that truncation left the suite GREEN at this head
# (verified), so the guard was ungraded. Driven: queue a stale 9 s interval, reset, then emit.
STG_LVL_TMP="$TMP/lvlq-reset"; : >"$STG_LVL_TMP"
printf '%s %s\n' l3_fix 9000000 >>"$STG_LVL_TMP"
stg_cycle_reset
STG_FIELD=""
stg_field STG_FIELD
_stale="$(cycle_stage_get "stages=$STG_FIELD" l3_fix 2>/dev/null || echo absent)"
ck "stg_cycle_reset TRUNCATES the overlay queue — a stale interval cannot leak into the next cycle (l3_fix reads '${_stale}', want 'ns')" \
   "$(if [ "$_stale" = "ns" ]; then echo 0; else echo 1; fi)"

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
