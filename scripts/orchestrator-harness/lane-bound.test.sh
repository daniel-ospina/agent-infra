#!/usr/bin/env bash
# lane-bound.test.sh — the lane LIFETIME bound (2026-10-27).
#
# ⛔ WHAT THIS SUITE IS FOR. Nine cloud-cell lanes parked with 0 bytes of output and `00:00:00` CPU,
# the oldest for 3 h 32 m, every one a `pi` in `ep_poll`; nothing bounded a lane's SILENCE, only its
# total duration. `lane-bound.sh` adds the missing axis and, just as importantly, a VERDICT:
# `stalled` / `exceeded-wallclock` carrying the last output size, the CPU delta and the elapsed time.
# So the checks below are of two kinds, and the second is the one that makes the first worth having:
#   1. the two limits behave — silence dies, chatty survives, silent-but-burning-CPU survives,
#      chatty-at-the-wall dies;
#   2. each limit is LOAD-BEARING — a mutant that defuses it turns its own case RED.
# A suite that only ran (1) would pass on a script whose bound had been wired to nothing.
#
# ⛔ NO NETWORK, NO MODEL, NO `timeout`, NO CELLS. Every "lane" here is a fixture script in $TMP: one
# that sleeps, one that prints, one that burns CPU, one whose TOOL CHILD burns CPU while it idles. The
# bound is driven through its real CLI, and every assertion reads the real verdict line it wrote.
#
# ⛔ PORTABILITY IS PROVEN, NOT CLAIMED (§f). One case is re-run under `sh` with a PATH built from
# symlinks in which `timeout` DOES NOT EXIST — `timeout` is absent on macOS, so a bound that depended
# on it would pass here and do nothing on every Mac and cell. The absence is ASSERTED, not assumed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOUND="$HERE/lane-bound.sh"
GATE="$HERE/spawn-gate.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
# want <haystack> <needle> — substring membership, as a FUNCTION rather than a `case` inside `$( )`.
# ⛔ MEASURED, AND IT MADE EVERY (h) ASSERTION UNREADABLE: a `case` nested inside a command substitution
# does not parse the way it looks — bash closes the substitution at the FIRST `)`, which is the one that
# ends the case PATTERN — so those assertions ran as a syntax error and their output read as a plain
# failure. An assertion that cannot run must never be mistakable for a result, hence a function.
want() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/logs"

echo "==> lane-bound self-test ($HERE)"

# ── 0) the subject exists, parses, and refuses an unbounded invocation ───────────────────────────
[ -s "$BOUND" ]; ck "lane-bound.sh exists and is non-empty" $?
bash -n "$BOUND"; ck "lane-bound.sh parses under bash" $?
sh -n "$BOUND"; ck "lane-bound.sh parses under POSIX sh" $?

# ⛔ A BOUND THAT CANNOT READ ITS OWN SIGNAL IS NOT A BOUND. `--log` is the output-growth signal; an
# omitted one must be REFUSED rather than silently degrade to a CPU-only bound, because the operator
# would then believe the silence bound is armed.
out="$(sh "$BOUND" run --idle 1 --wall 1 -- true 2>&1)"; brc=$?
# ⛔ HERE-STRINGS, NOT `printf … | grep -q` (#841): under `pipefail` the quiet grep exits at its first
# match, the writer takes SIGPIPE, and the PIPELINE status becomes 141 — so `rc=$?` would record a
# SIGPIPE instead of the match and this check would pass on a refusal that never printed its reason.
[ "$brc" -eq 2 ] && grep -q -- "--log is required" <<<"$out"; rc=$?
ck "refuses to run with no --log (an unreadable progress signal is a refusal, not a weaker bound) (rc=$brc)" $rc

# ⛔ AN EXPLICIT, UNREADABLE FLAG IS AN OPERATOR ERROR, NOT A TYPO TO SWALLOW — and it must NOT be
# defaulted, because defaulting `--idle 10m` to 1200 would arm a bound the operator had asked to change.
out="$(sh "$BOUND" run --log "$TMP/logs/x.log" --idle 10m -- true 2>&1)"; brc=$?
[ "$brc" -eq 2 ] && grep -q "not a whole number" <<<"$out"; rc=$?
ck "refuses a NON-NUMERIC --idle instead of defaulting it (rc=$brc)" $rc

# ── fixtures: the lanes, and one driver ──────────────────────────────────────────────────────────
cat > "$TMP/bin/silent.sh" <<'EOF'
#!/bin/sh
# The observed shape: a process that exists, prints nothing, burns no CPU. It is NOT dead and NOT done.
# The duration is a parameter so a mutation arm that removes the kill cannot park the suite on it.
sleep "${1:-20}"
EOF
cat > "$TMP/bin/chatty.sh" <<'EOF'
#!/bin/sh
# A working lane: keeps producing output. It must outlive the idle bound.
# $1 = the lane log it writes to (the bound measures GROWTH IN THAT FILE, which is what a real `pi`
# appending to `$O/logs/lane-<N>.log` does), $2 = tick count.
log="$1"; n="${2:-20}"; i=0
while [ "$i" -lt "$n" ]; do echo "tick $i" >> "$log"; sleep 0.2; i=$((i+1)); done
EOF
cat > "$TMP/bin/busy.sh" <<'EOF'
#!/bin/sh
# "SILENT BUT WORKING": prints nothing at all — a `pi -p` lane mid-test — while its CPU advances.
end=$(( $(date +%s) + ${1:-5} ))
while [ "$(date +%s)" -lt "$end" ]; do j=0; while [ "$j" -lt 100000 ]; do j=$((j+1)); done; done
EOF
cat > "$TMP/bin/units.sh" <<'EOF'
#!/bin/sh
# A lane COMPLETING UNITS OF WORK: one appended result + real CPU, every second. This is the fixture
# the censoring needs, because it is the one a progress bound must spare and a flat cap must not.
# $1 = the lane log it writes to, $2 = how many units.
log="$1"; n="${2:-8}"; i=0
while [ "$i" -lt "$n" ]; do
  printf 'completed unit %d\n' "$i" >> "$log"
  j=0; while [ "$j" -lt 50000 ]; do j=$((j+1)); done
  sleep 1; i=$((i+1))
done
EOF
cat > "$TMP/bin/parentidle.sh" <<'EOF'
#!/bin/sh
# THE REAL `pi` + TOOL SHAPE: the lane itself is silent AND flat, and the CPU belongs to its child.
# ⛔ THE CHILD MUST COVER THE LEADER'S WHOLE LIFE. The first draft had the child finish and the leader
# then sleep on with no CPU and no output — which IS a stall by the bound's own definition, so the
# fixture went red for a correct behaviour (and red only sometimes, depending on where the sampling
# boundaries fell). A fixture that models a quiet tail is not modelling the case it names.
"$0.busy" "${1:-5}" &
c=$!
while kill -0 "$c" 2>/dev/null; do sleep 0.2; done
wait "$c" 2>/dev/null
EOF
cp "$TMP/bin/busy.sh" "$TMP/bin/parentidle.sh.busy"
chmod +x "$TMP/bin"/*.sh "$TMP/bin/parentidle.sh.busy"

# drive <script> <tag> <idle> <wall> <log> <cmd...>  →  prints "rc=<n> verdict=<v>"
drive() {
  d_sc="$1"; d_tag="$2"; d_idle="$3"; d_wall="$4"; d_log="$5"; shift 5
  rm -f "$d_log" "$d_log.v"
  sh "$d_sc" run --log "$d_log" --idle "$d_idle" --wall "$d_wall" --grace 2 --tag "$d_tag" \
     --verdict-file "$d_log.v" -- "$@" >/dev/null 2>&1
  d_rc=$?
  d_v="$(sed -n 's/.*verdict=\([a-z-]*\).*/\1/p' "$d_log.v" 2>/dev/null | head -1)"
  printf 'rc=%s verdict=%s' "$d_rc" "${d_v:-none}"
}
field() { sed -n 's/.*[ ]'"$2"'=\([^ ]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
# nfield strips the unit suffix (`3s`) so a numeric comparison is comparing a NUMBER. The first draft
# compared "3s" with "-ge", which bash reports as `integer expression expected` and which silently
# turns every numeric assertion in this suite into a false negative.
nfield() { field "$1" "$2" | sed 's/[^0-9].*$//'; }

# ── (a) A LANE THAT PRINTS NOTHING AND BURNS NO CPU IS KILLED AT THE IDLE BOUND ──────────────────
# idle=2 against a fixture that would sleep 60 s: the ONLY thing that can end it is the silence bound.
res="$(drive "$BOUND" a 2 60 "$TMP/logs/a.log" "$TMP/bin/silent.sh" 20)"
[ "$res" = "rc=143 verdict=stalled" ]; ck "(a) a silent, CPU-flat lane is KILLED at the idle bound → $res" $?

# …and the kill carries its own evidence. A verdict without the numbers is a verdict an operator
# cannot act on, and the numbers are unrecoverable afterwards (the log is truncated on rerun and the
# CPU counter dies with the process), which is why they are asserted rather than described.
silent_v="$(nfield "$TMP/logs/a.log" silent)"
idle_b="$(nfield "$TMP/logs/a.log" idle_bound)"
bytes_a="$(nfield "$TMP/logs/a.log" bytes)"
dcpu_a="$(nfield "$TMP/logs/a.log" cpu_delta_cs)"
[ -n "$silent_v" ] && [ -n "$idle_b" ] && [ "$silent_v" -ge "$idle_b" ]; rc=$?
ck "(a) …and the verdict MEASURES the silence: silent=${silent_v:-?}s >= idle_bound=${idle_b:-?}s" $rc
[ "${bytes_a:-x}" = "0" ] && [ "${dcpu_a:-x}" = "0" ]; rc=$?
ck "(a) …both quiet signals are quoted: bytes=${bytes_a:-?} cpu_delta_cs=${dcpu_a:-?}" $rc
# The verdict is ONE line — "a single status line" is the contract an operator reads with `tail -1`.
nv="$(grep -c 'VERDICT' "$TMP/logs/a.log" 2>/dev/null || true)"
[ "${nv:-0}" = "1" ]; ck "(a) …and it is exactly ONE status line in the lane log (found ${nv:-0})" $?
# Every field an operator needs, present by NAME — a verdict that silently stops carrying `cpu_delta_cs`
# is a regression no exit code can see.
missing=""
for k in verdict tag pid rc elapsed wall_bound idle_bound silent bytes bytes_delta cpu_cs cpu_delta_cs tol_cs cpu_unreadable signal log; do
  [ -n "$(field "$TMP/logs/a.log" "$k")" ] || missing="$missing $k"
done
[ -z "$missing" ]; ck "(a) …the line carries every documented field (missing:${missing:- none})" $?

# ── (b) A LANE THAT KEEPS PRINTING IS NEVER KILLED, HOWEVER LONG ─────────────────────────────────
# 20 ticks x 0.2 s = ~4 s against a 2 s idle bound: it must live through TWO idle windows and finish.
res="$(drive "$BOUND" b 2 60 "$TMP/logs/b.log" "$TMP/bin/chatty.sh" "$TMP/logs/b.log" 20)"
[ "$res" = "rc=0 verdict=finished" ]; ck "(b) a lane whose OUTPUT keeps growing survives past the idle bound → $res" $?
silent_b="$(nfield "$TMP/logs/b.log" silent)"
[ -n "$silent_b" ] && [ "$silent_b" -lt 2 ]; rc=$?
ck "(b) …and its silence counter is reset by the growth (silent=${silent_b:-?}s < 2s)" $rc

# ── (c) "SILENT BUT WORKING" SURVIVES — THE CASE A SILENCE-ONLY BOUND WOULD KILL ─────────────────
# This is the mutation that matters: a `pi -p` lane prints nothing until it finishes, so an idle bound
# armed on OUTPUT ALONE kills every healthy lane. The CPU delta is the second, independent signal.
res="$(drive "$BOUND" c 2 60 "$TMP/logs/c.log" "$TMP/bin/busy.sh" 5)"
[ "$res" = "rc=0 verdict=finished" ]; ck "(c) a lane that prints NOTHING but accumulates CPU survives → $res" $?
[ "$(nfield "$TMP/logs/c.log" bytes)" = "0" ]; ck "(c) …and it really was silent (bytes=0), so the CPU signal is what saved it" $?
[ "$(nfield "$TMP/logs/c.log" cpu_cs)" -gt 10 ] 2>/dev/null; ck "(c) …with a measured CPU total, not an assumed one" $?

# (c2) the SUBTREE case — the shape a real lane has: `pi` idle, its tool child working. A bound that
# samples only the root pid reads this as silent-and-flat and kills a healthy lane.
res="$(drive "$BOUND" c2 2 60 "$TMP/logs/c2.log" "$TMP/bin/parentidle.sh" 5)"
[ "$res" = "rc=0 verdict=finished" ]; ck "(c2) a lane whose TOOL CHILD burns the CPU survives (subtree CPU, not the leader's own) → $res" $?

# (c3) AN UNREADABLE PROCESS TABLE MUST NOT ARM A KILL. `tools/fleet/liveness.py` and
# `extensions/task-heartbeat.ts` state the same rule: absence of evidence is never a decision. With the
# CPU probe broken the idle clause stands down and the WALL clock is the bound — a latency cost on a
# fail-safe path, never an unbound lane and never a dead healthy one.
REALPS="$(command -v ps)"
cat > "$TMP/bin/ps" <<EOF
#!/bin/sh
# A process table this box cannot read: the CPU probe fails, the liveness probe still works.
for a in "\$@"; do case "\$a" in *time=*) echo "ps: cannot read" >&2; exit 1 ;; esac; done
exec "$REALPS" "\$@"
EOF
chmod +x "$TMP/bin/ps"
rm -f "$TMP/logs/c3.log" "$TMP/logs/c3.log.v"
PATH="$TMP/bin:$PATH" sh "$BOUND" run --log "$TMP/logs/c3.log" --idle 2 --wall 5 --grace 2 --tag c3 \
  --verdict-file "$TMP/logs/c3.log.v" -- "$TMP/bin/busy.sh" 8 >/dev/null 2>&1
brc=$?
[ "$brc" -eq 143 ] && [ "$(field "$TMP/logs/c3.log" verdict)" = "exceeded-wallclock" ]; rc=$?
ck "(c3) with the CPU probe UNREADABLE the idle clause stands down and the WALL clock bounds the lane (rc=$brc)" $rc
[ "$(nfield "$TMP/logs/c3.log" cpu_unreadable)" -gt 0 ] 2>/dev/null; rc=$?
ck "(c3) …and the degradation is COUNTED in the verdict (cpu_unreadable=$(field "$TMP/logs/c3.log" cpu_unreadable))" $rc
rm -f "$TMP/bin/ps"

# ── (d) THE WALL CLOCK BOUNDS A CHATTY LANE TOO ──────────────────────────────────────────────────
# The idle bound is set far above the run so it cannot be what fires: a chatty lane at the ceiling is
# exactly the case the silence bound must NOT catch, and the ceiling must still end it.
res="$(drive "$BOUND" d 600 2 "$TMP/logs/d.log" "$TMP/bin/chatty.sh" "$TMP/logs/d.log" 60)"
[ "$res" = "rc=143 verdict=exceeded-wallclock" ]; ck "(d) the wall-clock ceiling kills even a chatty lane → $res" $?
[ "$(nfield "$TMP/logs/d.log" silent)" -lt 2 ] 2>/dev/null; rc=$?
ck "(d) …and it was NOT the silence bound that fired (silent=$(nfield "$TMP/logs/d.log" silent)s)" $rc

# ── (i) PROGRESS OVER THE WALL — the agent-infra#2888 regression, both directions ──────────────
# THE MEASURED DEFECT: `prfix` rows read median = p90 = 2400 s in `walltime.tsv` (the cap IS the
# median), and five of five lanes in one batch ended at `elapsed == cap` with zero commits and 144 KB
# of finished, uncommitted work. A lane that is WORKING must not be killed for taking long; a lane with
# no completed work for the allowance must be. (i1)/(i2) are the SAME fixture under two bounds — that
# pair is the censoring, red then green, and neither half is allowed to stand alone.
#
# A unit of work every 1 s, for 8 s: it is still working at 6 s and at 8 s.
UNIT_LANE=8

# (i1) GREEN: progress allowance governs, backstop above it → the lane finishes, nothing censors it.
res="$(drive "$BOUND" i1 2 12 "$TMP/logs/i1.log" "$TMP/bin/units.sh" "$TMP/logs/i1.log" "$UNIT_LANE")"
[ "$res" = "rc=0 verdict=finished" ]; ck "(i1) a lane that keeps COMPLETING units survives past the old flat cap → $res" $?
sil_i1="$(nfield "$TMP/logs/i1.log" silent)"
[ -n "$sil_i1" ] && [ "$sil_i1" -lt 2 ]; rc=$?
ck "(i1) …and it really was progressing the whole way (silent=${sil_i1:-?}s < 2s, elapsed=$(nfield "$TMP/logs/i1.log" elapsed)s)" $rc

# (i2) RED — the mutation is the SHIPPED pair (backstop below the work): the same fixture is killed.
# Asserted on the verdict AND on `silent`, because "killed at the wall" is only censoring when the
# lane was in fact still working; a wall kill of a quiet lane is the correct behaviour.
res="$(drive "$BOUND" i2 2 6 "$TMP/logs/i2.log" "$TMP/bin/units.sh" "$TMP/logs/i2.log" "$UNIT_LANE")"
[ "$res" = "rc=143 verdict=exceeded-wallclock" ]; ck "(i2) MUTATION (the flat cap): the SAME working lane IS killed at the backstop → $res" $?
sil_i2="$(nfield "$TMP/logs/i2.log" silent)"
[ -n "$sil_i2" ] && [ "$sil_i2" -lt 2 ]; rc=$?
ck "(i2) …and it was KILLED WHILE WORKING (silent=${sil_i2:-?}s < 2s) — that is the censoring, not a stall" $rc

# (i3) THE WEDGE KILL IS NOT TRADED AWAY. The backstop still ends a lane that never stops working
# (the "creeps forward for ever" class the progress rule cannot bound), so demoting the wall did not
# remove it — it moved the PROGRESS rule in front of it.
res="$(drive "$BOUND" i3 2 5 "$TMP/logs/i3.log" "$TMP/bin/units.sh" "$TMP/logs/i3.log" 60)"
[ "$res" = "rc=143 verdict=exceeded-wallclock" ]; ck "(i3) the BACKSTOP still kills a lane that keeps working for ever → $res" $?

# (i4) A BACKSTOP BELOW THE ALLOWANCE IS LOUD, because that ordering is the defect itself: it lets the
# wall pre-empt the progress rule so the rule can never reach its verdict. A WARN, not a refusal — a
# caller (and every case above) may arm a short wall deliberately to exercise the ceiling.
out="$(sh "$BOUND" run --log "$TMP/logs/i4.log" --idle 8 --wall 2 --grace 1 --tag i4 -- "$TMP/bin/silent.sh" 4 2>&1 || true)"
grep -q 'BACKSTOP (wall=2s) is NOT above the PROGRESS allowance (idle=8s)' <<<"$out"; rc=$?
ck "(i4) a backstop below the progress allowance WARNS that it will pre-empt it" $rc

# (i0) THE DOCTRINE COUPLING — one allowance, one backstop, and the numbers that must agree in the
# shipped tree. These are the assertions that stop a future edit from re-introducing the defect by
# raising one number and not the other (which is precisely how 2400 outlived 2700).
TS_EDGES="$HERE/../../extensions/shared/heartbeat-progress-edges.ts"
# The registry entry, not a bare literal search: the number must be read from the entry that OWNS it
# (`DEFAULT_PROGRESS_AGE_MS`) so this check tracks the doctrine rather than a comment beside it.
DOC_ALLOW_MS="$(awk '/name: "DEFAULT_PROGRESS_AGE_MS"/{f=1; next} f == 1 && /value:/{gsub(/[^0-9]/, ""); print; exit}' "$TS_EDGES" 2>/dev/null)"
DOC_ALLOW_S="$(( ${DOC_ALLOW_MS:-0} / 1000 ))"
[ "$DOC_ALLOW_S" = "2700" ]; ck "(i0) FIXTURE: the doctrine's allowance is readable from heartbeat-progress-edges.ts (${DOC_ALLOW_MS:-unreadable} ms)" $?
IDLE_DEF="$(sed -n 's/.*num_or "${LANE_BOUND_IDLE_S:-}" \([0-9][0-9]*\)).*/\1/p' "$BOUND" | head -1)"
[ "${IDLE_DEF:-x}" = "$DOC_ALLOW_S" ]; ck "(i0) the PROGRESS allowance default (${IDLE_DEF:-?}s) IS the fleet's declared no-progress allowance (${DOC_ALLOW_S}s) — one number, not two" $?
WALL_DEF="$(sed -n 's/.*num_or "${LANE_BOUND_WALL_S:-}" \([0-9][0-9]*\)).*/\1/p' "$BOUND" | head -1)"
[ -n "${WALL_DEF:-}" ] && [ "$WALL_DEF" -gt "${IDLE_DEF:-0}" ]; rc=$?
ck "(i0) the BACKSTOP default (${WALL_DEF:-?}s) sits ABOVE the allowance (${IDLE_DEF:-?}s), so it cannot pre-empt it" $rc
SEAM="$(sed -n 's/^LANE_BACKSTOP_S="${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}".*/\1/p' "$GATE" | head -1)"
[ -n "${SEAM:-}" ] && [ "$SEAM" -gt "${IDLE_DEF:-0}" ]; rc=$?
ck "(i0) the shipped lane BACKSTOP (LANE_BACKSTOP_S=${SEAM:-?}s) is above the allowance, so a wedged lane dies by PROGRESS, never by the wall" $rc
PRD="$HERE/../pr-doctor.py"
PRD_DEF="$(sed -n 's/^DEFAULT_SPAWN_BACKSTOP_S = \([0-9][0-9]*\).*/\1/p' "$PRD" | head -1)"
[ -n "${PRD_DEF:-}" ] && [ "$PRD_DEF" = "$SEAM" ]; rc=$?
ck "(i0) pr-doctor's backstop default (${PRD_DEF:-?}s) equals the harness seam (${SEAM:-?}s) — a python/branch literal pair that CANNOT drift" $rc
REAP_LIVE="$(sed -n 's/^LIVE_MIN="${LANE_REAP_LIVE_MIN:-\([0-9][0-9]*\)}".*/\1/p' "$HERE/lane-reap.sh" | head -1)"
[ -n "${REAP_LIVE:-}" ] && [ $(( REAP_LIVE * 60 )) -gt "${SEAM:-0}" ]; rc=$?
ck "(i0) the reaper's LIVE window (${REAP_LIVE:-?} min) stays above the BACKSTOP (${SEAM:-?}s) — a live lane is not counted dead for capacity" $rc

# ⛔ THE TWO CONSUMERS THAT OUTLIVE THE LANE, AND THEREFORE READ ITS CLOCK THEMSELVES (agent-infra#2888).
# Neither sources spawn-gate.sh, so each carries the seam as a literal fallback — which is exactly the
# drift this pins. A `3320e-11`-era default here is not cosmetic: `chain-merge.sh` DELETES a merge marker
# it judges stale and reviews at the tip, and `ai-drainer.sh` re-dispatches a slice it judges unheld, so
# a value below the backstop makes a LIVE lane look gone. Driven from the shipped files, not from prose.
DRAIN_DEF="$(sed -n 's/^LANE_TIMEOUT="${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}}".*/\1/p' "$HERE/ai-drainer.sh" | head -1)"
[ -n "${DRAIN_DEF:-}" ] && [ "$DRAIN_DEF" = "${SEAM:-x}" ]; rc=$?
ck "(i0) ai-drainer's LANE_TIMEOUT (${DRAIN_DEF:-?}s) is the harness BACKSTOP (${SEAM:-?}s), not a 3000 s literal below it" $rc
# ...and its coercion fallback too: `_num` on a malformed value must land on the same number, or a typo
# shortens the window the same way the literal did.
DRAIN_COERCE="$(sed -n 's/^LANE_TIMEOUT="$(_num LANE_TIMEOUT "$LANE_TIMEOUT" \([0-9][0-9]*\))".*/\1/p' "$HERE/ai-drainer.sh" | head -1)"
[ -n "${DRAIN_COERCE:-}" ] && [ "$DRAIN_COERCE" = "${SEAM:-x}" ]; rc=$?
ck "(i0) …and its malformed-value fallback (${DRAIN_COERCE:-?}s) is the same number, so a typo cannot shorten it" $rc
CHAIN_FB="$(sed -n 's/.*_PHASE_STALE_AFTER="${LANE_TIMEOUT:-${LANE_BACKSTOP_S:-\([0-9][0-9]*\)}}".*/\1/p' "$HERE/chain-merge.sh" | head -1)"
[ -n "${CHAIN_FB:-}" ] && [ "$CHAIN_FB" = "${SEAM:-x}" ]; rc=$?
ck "(i0) chain-merge's stale-marker fallback (${CHAIN_FB:-?}s) is the harness BACKSTOP, so a working lane's marker is not declared stale" $rc
# The seam itself must REACH those children: an unexported variable leaves an operator's override at
# home while the child reads the compiled default (the "knob that does nothing" shape again).
grep -q '^export LANE_BACKSTOP_S$' "$GATE"; ck "(i0) spawn-gate.sh EXPORTS LANE_BACKSTOP_S, so a lane's children agree with the clock it runs under" $?

# A literal-substring replacement, so no regex/`$` quoting can silently no-op the mutation, and the
# replacement is ASSERTED to have landed: a mutant identical to the original would make every
# "the case reddens" check vacuous, which is the "test that cannot fail" class.
mutate() { # mutate <src> <dst> <from> <to>
  awk -v from="$3" -v to="$4" '
    { i = index($0, from); if (i > 0 && !done) { $0 = substr($0, 1, i - 1) to substr($0, i + length(from)); done = 1 } print }
  ' "$1" > "$2"
  cmp -s "$1" "$2" && return 1
  return 0
}

# (e1) DEFUSE THE IDLE CLAUSE ⇒ (a)'s stalled verdict is GONE. The mutant is not required to produce a
# particular OTHER outcome (a defused clause can end at the wall or not at all) — only to STOP STALLING,
# which is exactly the assertion (a) makes and the only thing the mutation claims.
mutate "$BOUND" "$TMP/m1.sh" 'enforce stalled ' ': stalled '; m=$?
ck "(e1) the idle-defused mutant was actually produced (a no-op mutation would prove nothing)" $m
if [ "$m" -eq 0 ]; then
  res="$(drive "$TMP/m1.sh" e1 2 4 "$TMP/logs/e1.log" "$TMP/bin/silent.sh" 6)"
  case "$res" in *verdict=stalled) rc=1 ;; *) rc=0 ;; esac
  ck "(e1) MUTATION: with the idle check defused, (a)'s stalled verdict is GONE → $res" $rc
fi

# (e2) DEFUSE THE CPU-DELTA SIGNAL ⇒ (c) reddens (the silent-but-working lane is killed as stalled).
# This is the mutation the brief names as the one that matters: it is what separates a silence bound
# from a stall bound.
mutate "$BOUND" "$TMP/m2.sh" '_lb_dcpu=$(( _lb_cpu - _lb_prev_cpu ))' '_lb_dcpu=0'; m=$?
ck "(e2) the CPU-signal-defused mutant was actually produced" $m
if [ "$m" -eq 0 ]; then
  res="$(drive "$TMP/m2.sh" e2 2 30 "$TMP/logs/e2.log" "$TMP/bin/busy.sh" 5)"
  # ⛔ THE MUTATION'S CLAIM IS "THE LANE IS KILLED", NOT THE EXIT STATUS. A TERM that lands as the
  # fixture finishes naturally yields rc=0 with verdict=stalled, and that is a correct kill — asserting
  # rc=143 here made the suite flaky on a fact the mutation never claimed.
  want "$res" "verdict=stalled"; rc=$?
  ck "(e2) MUTATION: without the CPU delta, (c)'s silent-but-working lane IS killed → $res" $rc
fi

# (e3) DEFUSE THE OUTPUT-GROWTH SIGNAL ⇒ (b) reddens.
mutate "$BOUND" "$TMP/m3.sh" '_lb_dbytes=$(( _lb_bytes - _lb_prev_bytes ))' '_lb_dbytes=0'; m=$?
ck "(e3) the output-signal-defused mutant was actually produced" $m
if [ "$m" -eq 0 ]; then
  res="$(drive "$TMP/m3.sh" e3 2 30 "$TMP/logs/e3.log" "$TMP/bin/chatty.sh" "$TMP/logs/e3.log" 20)"
  want "$res" "verdict=stalled"; rc=$?
  ck "(e3) MUTATION: without the output-growth signal, (b)'s chatty lane IS killed → $res" $rc
fi

# (e4) DEFUSE THE SUBTREE WALK (root CPU only) ⇒ (c2) reddens, (c) still passes. That pair is what
# proves the walk measures the TREE rather than happening to agree with the leader on this fixture.
mutate "$BOUND" "$TMP/m4.sh" '{ inc[pid[i]] = 1; changed = 1 }' '{ changed = 0 }'; m=$?
ck "(e4) the subtree-walk-defused mutant was actually produced" $m
if [ "$m" -eq 0 ]; then
  res="$(drive "$TMP/m4.sh" e4 2 30 "$TMP/logs/e4.log" "$TMP/bin/parentidle.sh" 5)"
  want "$res" "verdict=stalled"; rc=$?
  ck "(e4) MUTATION: with the walk defused, (c2)'s idle-leader/busy-child lane IS killed → $res" $rc
  # NON-VACUITY OF (e4): the same mutant must still PASS the leader-only case, or (e4) would be
  # measuring "the mutant is broken" rather than "the subtree walk is load-bearing".
  res="$(drive "$TMP/m4.sh" e4b 2 30 "$TMP/logs/e4b.log" "$TMP/bin/busy.sh" 5)"
  [ "$res" = "rc=0 verdict=finished" ]; rc=$?
  ck "(e4) …while the leader-own-CPU case still passes under the SAME mutant → $res" $rc
fi

# ── (f) PORTABILITY: NO `timeout`, POSIX `sh`, AND THE ABSENCE IS ASSERTED ───────────────────────
# `timeout` does not exist on macOS, so a bound built on it would work in this suite (where GNU
# coreutils may be on PATH) and do NOTHING on every Mac and cell. The PATH below is built from
# symlinks to exactly the commands the bound is allowed to need; `timeout` is not one of them, and the
# check before the run proves the shim PATH really lacks it — otherwise the case would prove nothing.
P="$TMP/path"; mkdir -p "$P"
for c in sh ps awk wc tr date sleep kill sed cat; do
  rc_="$(command -v "$c" 2>/dev/null)" && ln -sf "$rc_" "$P/$c"
done
pout="$(PATH="$P" sh -c 'command -v timeout' 2>/dev/null || true)"
[ -z "$pout" ]; ck "(f) FIXTURE: the restricted PATH really has NO 'timeout' in it (${pout:-absent})" $?
rm -f "$TMP/logs/f.log" "$TMP/logs/f.log.v"
PATH="$P" sh "$BOUND" run --log "$TMP/logs/f.log" --idle 2 --wall 60 --grace 2 --tag f \
  --verdict-file "$TMP/logs/f.log.v" -- "$P/sh" "$TMP/bin/silent.sh" 20 >/dev/null 2>&1
brc=$?
[ "$brc" -eq 143 ] && [ "$(field "$TMP/logs/f.log" verdict)" = "stalled" ]; rc=$?
ck "(f) the SAME bound runs under POSIX sh with no 'timeout' on PATH and still fires (rc=$brc)" $rc

# ── (h) THE WIRING, DRIVEN — not grepped ────────────────────────────────────────────────────────
# ⛔ THE CHECKS IN (g) ARE SOURCE-SHAPE ASSERTIONS, AND A SOURCE-SHAPE ASSERTION PASSES ON A SCRIPT
# WHOSE RUNTIME LOST THE TEXT (this repo's own "test that cannot fail" class). So the SHIPPED
# `run_agent` is DRIVEN here, with a stub `pi` on PATH and the same hermetic rig `brief-gate.test.sh`
# established for it: a fixture repo whose origin is a GitHub slug, a stub `gh` (so the creation
# back-pressure gate gets a reading rather than a network call), an isolated HOME/$O, `load1` pinned,
# and the canonical brief so the research gate admits it.
FIXREPO="$TMP/repofix"; mkdir -p "$FIXREPO" "$TMP/fakehome" "$TMP/o/state"
git init -q "$FIXREPO" && git -C "$FIXREPO" remote add origin https://github.com/owner/repo.git
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# A real brief: `run_agent` REFUSES one without the research contract (80) BEFORE it spawns anything,
# so a fixture of `printf 'a prompt\n'` would make every case below a brief refusal that measures nothing.
{ printf 'a lane brief for the bound suite\n\n'; bash "$HERE/brief-gate.sh" --section lane 2>/dev/null; } > "$TMP/brief.txt"
bash "$HERE/brief-gate.sh" --check "$TMP/brief.txt" lane 2>/dev/null
ck "(h) FIXTURE: the suite's own brief passes the research gate (else every case below measures the gate)" $?

# The driver is a FILE, not a `bash -c` payload: the run's shell is part of what is under test.
cat > "$TMP/bin/drive_ra.sh" <<'EOF'
#!/bin/bash
# $1 = the shipped spawn-gate.sh, $2 = wall limit, $3 = log, $4 = brief
. "$1" || exit 9
load1() { printf "1"; }
cd "$FIXREPO" || exit 9
t0=$(date +%s)
run_agent "$2" "$3" "$4" "lane-bound test" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - t0 ))
printf 'rc=%s started=%s elapsed=%s bound=%s' "$rc" "$AGENT_STARTED" "$elapsed" "${AGENT_BOUND_VERDICT:-none}"
EOF

# The observed shape: a `pi` that starts, prints nothing and burns no CPU.
printf '#!/bin/sh\necho PI_STARTED >> "$PI_LOG"\nsleep 60\n' > "$TMP/bin/pi"; chmod +x "$TMP/bin/pi"
export PI_LOG="$TMP/pi.log"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" O="$TMP/o" HOME="$TMP/fakehome" FIXREPO="$FIXREPO" MAX_LOAD=1000 \
        DISK_MIN_FREE_MB=1 KIND=lane LANE_BOUND_IDLE_S=2 \
        bash "$TMP/bin/drive_ra.sh" "$GATE" 120 "$TMP/logs/h.log" "$TMP/brief.txt")"
want "$res" "bound=stalled"; rc=$?
ck "(h) run_agent reports a SILENT lane through AGENT_BOUND_VERDICT ($res)" $rc
want "$res" "started=1"; rc=$?
ck "(h) …and the agent really started, so the verdict is evidence rather than a vacuous green ($res)" $rc
# The bound must have ended it EARLY, not at the 120 s wall — otherwise this would pass on a tree with
# no idle axis at all, which is precisely the pre-change behaviour.
case "$res" in
  *elapsed=1[0-9]*|*elapsed=[2-9]*) rc=0 ;;
  *) rc=1 ;;
esac
ck "(h) …and it ended the lane EARLY rather than at the 120s wall ($res)" $rc
[ -s "$TMP/logs/h.log.lanebound" ]; ck "(h) …and the verdict file lands beside the lane log, where an operator looks" $?
# …and the log an operator greps carries it too, with the measurements. The bound writes the VERDICT
# line into the lane log itself; this is the surface the README tells an operator to `grep`.
grep -q 'lane-bound\] VERDICT verdict=stalled' "$TMP/logs/h.log"; ck "(h) …and the lane LOG carries the verdict line with its measurements" $?
grep -q PI_STARTED "$PI_LOG"; ck "(h) …the stub pi really ran (so the verdict is evidence, not a vacuous green)" $?

# POSITIVE CONTROL — the same wiring must NOT kill a lane that is producing output.
# ⛔ WRITTEN AS A HEREDOC, NOT A `printf` FORMAT: `printf '… date +%s …'` consumes the `%s` as a FORMAT
# SPECIFIER and silently writes `date +` into the fixture, so the stub died on line 3 and the control
# "passed" on a lane that produced nothing — a vacuous control measuring a broken fixture.
cat > "$TMP/bin/pi" <<'PISTUB'
#!/bin/sh
i=0
while [ "$i" -lt 20 ]; do echo "tick $i"; sleep 0.2; i=$((i+1)); done
exit 0
PISTUB
chmod +x "$TMP/bin/pi"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" O="$TMP/o" HOME="$TMP/fakehome" FIXREPO="$FIXREPO" MAX_LOAD=1000 \
        DISK_MIN_FREE_MB=1 KIND=lane LANE_BOUND_IDLE_S=2 \
        bash "$TMP/bin/drive_ra.sh" "$GATE" 120 "$TMP/logs/h2.log" "$TMP/brief.txt")"
want "$res" "rc=0 started=1 elapsed="; rc=$?
[ "$rc" -eq 0 ] && want "$res" "bound=none"; rc=$?
ck "(h) POSITIVE CONTROL: a lane whose output keeps growing is NOT killed by the same wiring ($res)" $rc
# ⛔ AND THE CONTROL IS NOT VACUOUS: the stub must really have printed for ~4 s. Without this, a stub
# that died instantly would satisfy `rc=0 bound=none` and the control would prove nothing at all
# (measured: that is exactly what a `printf`-mangled fixture did here before this assertion existed).
ticks="$(grep -c '^tick ' "$TMP/logs/h2.log" 2>/dev/null || true)"
[ "${ticks:-0}" -ge 10 ]; rc=$?
ck "(h) …and the control stub really produced output past the idle bound (${ticks:-0} ticks)" $rc

# ⛔ (h3) THE BACKSTOP SEAM IS REACHABLE THROUGH `run_agent` (agent-infra#2888). `lane-bound.sh`
# documents `LANE_BOUND_WALL_S` (flag → env → default), but `run_agent` passes `--wall "$t"` on EVERY
# run, so before this change that knob was INERT on every wired path — an operator setting it would
# have changed nothing while believing the bound had moved. Driven, not grepped: a chatty lane and a
# 3 s backstop; if the seam is dead the lane finishes and this stays RED.
res="$(PATH="$TMP/bin:$PATH" O="$TMP/o" HOME="$TMP/fakehome" FIXREPO="$FIXREPO" MAX_LOAD=1000 \
        DISK_MIN_FREE_MB=1 KIND=lane LANE_BOUND_IDLE_S=30 LANE_BOUND_WALL_S=3 \
        bash "$TMP/bin/drive_ra.sh" "$GATE" 120 "$TMP/logs/h3.log" "$TMP/brief.txt")"
want "$res" "bound=exceeded-wallclock"; rc=$?
ck "(h3) LANE_BOUND_WALL_S reaches the bound through run_agent (it used to be an inert knob) ($res)" $rc
grep -q 'backstop OVERRIDDEN by LANE_BOUND_WALL_S=3' "$TMP/logs/h3.log"; rc=$?
ck "(h3) …and the override is NAMED in the lane log, so the bound that ran and the bound reported cannot disagree" $rc

# ── (g) THE CALLER'S CONTRACT: `run_agent` reads the verdict, and a stale one cannot be mistaken ──
# A caller that cannot tell "the lane finished" from "the bound ended it" reports a wedged lane as a
# completed one. The wiring is asserted against the SHIPPED spawn-gate.sh, not against a copy.
grep -q 'lane_bound_path' "$GATE"; ck "(g) spawn-gate.sh resolves the bound instead of assuming it is installed" $?
grep -q 'AGENT_BOUND_VERDICT' "$GATE"; ck "(g) …and exposes its verdict to callers as AGENT_BOUND_VERDICT" $?
# ⛔ THE DEGRADED PATH IS STILL A BOUND, AND IT IS STILL THERE. A `$O` older than this change has no
# `lane-bound.sh`; `run_agent` then logs a WARN and falls back to the wall clock alone. Asserting the
# fallback exists is the other half of "a version skew must never halt every lane": the failure this
# guards is a future edit that deletes the subshell while keeping the WARN, which would advertise a
# bound the box does not have.
grep -qF 'sleep "$_lb_wall"; kill -TERM "$pid"' "$GATE"; ck "(g) …and a \$O without lane-bound.sh still gets the WALL CLOCK (loudly), never an unbounded lane" $?
# ⛔ THE VERDICT FILE IS REMOVED BEFORE EACH RUN. A leftover from a previous invocation of the same log
# would be read as THIS run's outcome — the stale-flag class the harness names in its own instructions.
awk '/rm -f "\$log.lanebound"/{f=1} /sh "\$_lb_sh" watch/{w=1} END{exit !(f && w && NR>0)}' "$GATE" \
  && [ "$(awk '/rm -f "\$log.lanebound"/{r=NR} /sh "\$_lb_sh" watch/{w=NR} END{print (r && w && r<w) ? 0 : 1}' "$GATE")" = 0 ]
ck "(g) …and CLEARS the verdict file BEFORE launching the watchdog (a stale verdict is never this run's)" $?

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
