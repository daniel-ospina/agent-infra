#!/usr/bin/env bash
# spawn-gate.test.sh — the load gate and the ONE agent invocation (agent-infra#1720, #8521 port).
#
# HOW THESE CHECKS ARE WRITTEN. The subject is the SHIPPED `spawn-gate.sh`: every check below
# sources that file and drives the real `run_agent`/`can_spawn`/`load1`, then asserts on what they
# DID — whether the stub `pi` was executed, what the walltime ledger received, which exit code came
# back. A check that re-implements the gate passes on the ungated tree too, which is the vacuity
# this suite exists to avoid. `load1` is the one function the test RE-DECLARES after sourcing, and
# that is a seam rather than a stub of the logic under test: run_agent()'s contract is "read load
# IMMEDIATELY before the spawn", and that reading has to be controllable to test the contract at all.
#
# ⛔ `rc=$?` IS CAPTURED ON THE LINE IMMEDIATELY AFTER EVERY TESTED COMMAND, never `ck "… $?"`.
# `$?` inside a `ck` argument is expanded AFTER any `$(…)` in that argument has run, so a message
# that inspects a file silently substitutes the STATUS OF `cat` — the same defect §7.4 records for
# retired/do-merge.sh, and it made three checks here pass on an empty file while writing this port.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GATE="$HERE/spawn-gate.sh"
mkdir -p "$TMP/bin" "$TMP/O/state"
LOG="$TMP/log"; PROMPT="$TMP/prompt"; PI_LOG="$TMP/pi.log"; MERGE_LOG="$TMP/merge.log"
printf 'a prompt\n' > "$PROMPT"

echo "==> spawn-gate self-test ($HERE)"

# ── 1) the helper exists, parses, and is SOURCED (never executed) by its callers ─
[ -s "$GATE" ] && bash -n "$GATE"; rc=$?
ck "spawn-gate.sh exists and parses" $rc

# A `run_agent` that a caller never received is worse than none: an unset function is a 127 at the
# SPAWN SITE, not a load-time error, so a caller must FAIL LOUD when the helper is absent rather
# than carry on ungated. Assert the guard, not merely the source line.
for f in lane.sh fix-one.sh; do
  grep -q '\. "\$SELF/spawn-gate.sh" ||' "$HERE/$f"; rc=$?
  ck "$f refuses to run when spawn-gate.sh is missing (fail loud, not 127 at the spawn)" $rc
done
# ⛔ THE GREPS ABOVE ARE NOT THE GUARD (P2, review round 2026-10-15, second pass). A source-line grep
# passes on a guard body that no longer fails: `. "$SELF/spawn-gate.sh" || true` left this suite at
# 47 passed / 0 failed, so the exact failure the check names — a caller carrying on ungated, leaving
# `run_agent` undefined and a 127 at the SPAWN SITE — would ship green. So drive it: copy each caller
# into a scratch dir with NO helper beside it and require the loud, non-zero refusal.
NX="$TMP/nogate"; mkdir -p "$NX/O/logs"
cp "$HERE/lane.sh" "$HERE/fix-one.sh" "$NX/"
out="$( ( cd "$NX" && O="$NX/O" bash "$NX/lane.sh" 9999 work daniel-ospina/agent-infra ) 2>&1 )"; nrc=$?
{ [ "$nrc" -eq 78 ] && printf '%s' "$out" | grep -q 'FATAL'; }; rc=$?
ck "lane.sh truly REFUSES (exit 78 + FATAL) with no helper beside it — driven, not grepped (rc=$nrc)" $rc
# fix-one.sh takes FOUR positional args, and PR must be numeric or it bails at its FIRST guard
# (exit 1) and never reaches the source line — which would make this check pass for the wrong reason.
out="$( ( cd "$NX" && O="$NX/O" bash "$NX/fix-one.sh" "$NX" daniel-ospina/agent-infra 7 work ) 2>&1 )"; nrc=$?
{ [ "$nrc" -eq 78 ] && printf '%s' "$out" | grep -q 'FATAL'; }; rc=$?
ck "fix-one.sh truly REFUSES (exit 78 + FATAL) with no helper beside it — driven, not grepped (rc=$nrc)" $rc

# ⛔ SOURCED AFTER `export PATH`. spawn-gate.sh resolves `_NCPU` at SOURCE time through
# sysctl/nproc/getconf, so a caller that sources it above its PATH export pins _NCPU=4 and
# MAX_LOAD=40 on every cell — the #1702 failure the portable probe exists to prevent.
for f in lane.sh fix-one.sh; do
  src="$(grep -n 'spawn-gate.sh"' "$HERE/$f" | head -1 | cut -d: -f1)"
  pexp="$(grep -n '^export PATH=' "$HERE/$f" | head -1 | cut -d: -f1)"
  if [ -n "$src" ] && [ -n "$pexp" ] && [ "$src" -gt "$pexp" ]; then rc=0; else rc=1; fi
  ck "$f sources the helper AFTER its PATH export (line $src > $pexp)" $rc
done

# ── 2) exactly ONE shipped file invokes the model ────────────────────────────────
# The defect was three copy-pasted spawn sites plus a fourth launch path nobody routed. A grep for
# "run_agent" would pass on a file that defines it and never calls it, so this counts the actual
# INVOCATION and asserts the SET rather than a total: a new launch path fails here until it is
# routed through the helper, and porting the remaining caller is an explicit, visible edit.
#
# ⛔ TWO SCOPES, BOTH ASSERTED, AND A TOKEN PATTERN RATHER THAN A LITERAL (P2, review round
# 2026-10-15). A census built from `$HERE/*.sh` with `grep 'pi -p '` says nothing about the rest of
# the tree and misses every other spelling: `scripts/cloud-cell-bringup.sh` was an ungated invoker
# the check could not see while it claimed to speak for the tree, and `"$PI_BIN" -p`, `pi  -p`,
# a tab, and `pi --print` are all invisible to the literal. So: census the WHOLE tracked scripts/
# tree, match the command TOKEN, and pin both sets as equalities. `retired/` is excluded — retired
# scripts cannot be dispatched — and named here so the exclusion is visible rather than silent.
scan_pi() { # scan_pi <pathspec...>  → space-separated repo-relative paths
  # ⛔ THE CENSUS IS ADJACENCY-FREE, AND THAT IS THE POINT. Four review rounds went into this one
  # predicate, so the history lives here rather than in commit messages:
  #   • round 2 keyed on `pi` IMMEDIATELY followed by `-p` → blind to `pi --no-session -p`.
  #   • round 3 switched to a same-LINE flag pair → REGRESSED the line-continuation case that
  #     round 2 had caught: `grep -E` is line-based, so `pi -p \` + newline + `--no-session`
  #     presents one token per line.
  #   • round 4 made the boundary delimiter-agnostic but kept ADJACENCY and a `*.sh|*.py|*.mjs|…`
  #     allow-list → still blind to a multi-line argv LIST (an idiomatic Python/JS launcher) and to
  #     `.cjs` / extensionless launchers, which this tree already ships.
  # So the test is the TOKEN PAIR, not their proximity: a file is an invoker if it carries a
  # print-mode flag as a TOKEN and `--no-session` ANYWHERE. No line joining, no flag order, and an
  # EXCLUSION list of non-launcher paths rather than an extension allow-list (a new extension cannot
  # silently drop a launch path out of the census).
  # STATED LIMIT: an invocation that omits `--no-session` (the harness convention requires it), or one
  # whose command name AND flags are both assembled at runtime, is outside a static census — that
  # residue is the runtime `run_agent` contract's job, not a grep's.
  local p found="" FLAG
  FLAG='(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)'
  while IFS= read -r p; do
    case "$p" in
      */retired/*|*/testdata/*|*.test.*|*/selftest.sh|*.md|*.txt|*.json|*.env) continue ;; esac
    grep -qE -e "$FLAG" "$ROOT/$p" 2>/dev/null || continue
    grep -qF -e '--no-session' "$ROOT/$p" 2>/dev/null || continue
    found="$found $p"
  done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard "$@")
  printf '%s' "${found# }"
}
# The censuses need a git work tree: `git ls-files` is the index-bounded primitive (per AGENTS.md
# "Search"), and if it fails the set comes back empty and the EQUALITY below goes RED — fail-closed,
# which is the right direction for a guard whose job is "no ungated launch path exists".
ROOT="$(cd "$HERE/../.." && pwd)"
# merge-one.sh is NOT ported here: it is owned by a concurrent lane (PR #1769/#1730). The assertion
# is deliberately an EQUALITY, so the residual is asserted rather than left silent, and a THIRD
# pi-invoker — or a regression in either of these two — fails it.
EXPECTED_PI="merge-one.sh spawn-gate.sh"
got_pi="$(scan_pi 'scripts/orchestrator-harness/*' | sed "s#scripts/orchestrator-harness/##g")"
[ "$got_pi" = "$EXPECTED_PI" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      pi-invokers found: [${got_pi:-<none>}]"
ck "the pi-invokers in scripts/orchestrator-harness are exactly [$EXPECTED_PI]" $rc

# ... and the WIDER tree, because a directory-scoped census cannot see outside itself. This one
# caught a real gap: `scripts/cloud-cell-bringup.sh` invokes `pi -p` with no load gate at all. It is
# a 120 s provider REACHABILITY probe rather than a lane dispatch (see the harness README §6), so it
# is not routed through run_agent() here — but it is asserted BY NAME, so a new ungated invoker
# anywhere under scripts/ fails this check instead of arriving unannounced.
EXPECTED_PI_TREE="scripts/cloud-cell-bringup.sh scripts/orchestrator-harness/merge-one.sh scripts/orchestrator-harness/spawn-gate.sh"
got_tree="$(scan_pi 'scripts/*')"
[ "$got_tree" = "$EXPECTED_PI_TREE" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      tree-wide pi-invokers found: [${got_tree:-<none>}]"
ck "the tree-wide pi-invokers are exactly [${EXPECTED_PI_TREE}] (cloud-cell-bringup.sh declared)" $rc

# ... and the ported callers must have no spawn logic of their own left behind.
for f in lane.sh fix-one.sh; do
  if grep -qE '^run_agent\(\)' "$HERE/$f"; then rc=1; else rc=0; fi
  ck "$f no longer defines its own run_agent() (one copy, in the helper)" $rc
done

# ── 3) load1 reads the 1-min load on BOTH platforms ─────────────────────────────
# /proc field 1 IS the 1-min load; macOS `sysctl vm.loadavg` prints `{ 1m 5m 15m }`, where awk sees
# the brace as $1 so the 1-min load is $2. One shared awk reads the wrong thing on one of the two.
got="$(. "$GATE" 2>/dev/null; printf '4.50 1.00 2.00\n' > "$TMP/loadavg"; load1 "$TMP/loadavg" 2>/dev/null)"
[ "$got" = "4" ]; rc=$?
ck "load1 reads field 1 from a /proc/loadavg file (got '${got:-<none>}', want 4)" $rc

if [ -r /proc/loadavg ]; then
  echo "  ⏭  skip: this host has /proc/loadavg, so load1's sysctl branch is unreachable here"
else
  # macOS. A fake `sysctl` is the only way to drive the real branch. The three values DIFFER
  # (3.10 / 7.90 / 2.00) so the check discriminates: the 1-min load is 3, a shared awk reading $1
  # gives 0 (the brace), and a 5-min read gives 7.
  printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "vm.loadavg" ] && { echo "{ 3.10 7.90 2.00 }"; exit 0; }\nexit 1\n' > "$TMP/bin/sysctl"
  chmod +x "$TMP/bin/sysctl"
  got="$(PATH="$TMP/bin:$PATH" bash -c '. "$1"; load1' _ "$GATE" 2>/dev/null)"
  [ "$got" = "3" ]; rc=$?
  ck "load1 reads the 1-min load from sysctl vm.loadavg on macOS (got '${got:-<none>}', want 3)" $rc
fi

# ── 4) MAX_LOAD coercion: a bad plist value must CLOSE the gate, not open it ─────
# `[ -lt ]` on a non-number ERRORS, and `can_spawn` returns that status — but every caller tests
# `if ! can_spawn …`, so the error makes the branch TRUE and the spawn is REFUSED (fail-CLOSED,
# measured). So this coercion is not about an open gate: it is about the WRAP below, a 0-valued
# probe, and a 19-digit ceiling. The older rationale ("a false test in the gate chain ALLOWS") is
# wrong for this polarity and is deliberately NOT repeated here.
# typo in the plist would remove the back-pressure. Leading zeros are the subtle half: `$(( ))`
# parses base 0, so `08` reaches `[ "$L" -ge "08" ]`, which ERRORS (also false => OPEN). The
# magnitude is the third: a 19-digit MAX_LOAD passes a digits-only test and errors every `[ -ge ]`.
for bad in "08" "abc" "" "9223372036854775807" " 5"; do
  got="$(MAX_LOAD="$bad" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
  case "$got" in 0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) rc=0 ;; *) rc=1 ;; esac
  ck "MAX_LOAD='$bad' is coerced to a usable integer (got '${got:-<empty>}')" $rc
done
# ... and the derived default uses the PORTABLE probe, not `|| echo 4` (which pinned every Linux
# cell to 4 cores / MAX_LOAD=40, #1702).
want_ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
got="$(env -u MAX_LOAD bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "$(( 10#$want_ncpu * 10 ))" ]; rc=$?
ck "the derived MAX_LOAD is 10 x the PORTABLE core count (got '${got:-<none>}', want $(( 10#$want_ncpu * 10 )))" $rc

# ⛔ A 0-VALUED PROBE IS A FAILED PROBE, NOT "NO CORES" (P1, 2026-10-15 review). `10 * 0` is 0,
# `is_num 0` is TRUE, and `[ "$l" -lt 0 ]` is ALWAYS FALSE — so a probe that returns 0 CLOSES the
# gate permanently and the box dispatches nothing, forever, in silence. The mirror case is just as
# bad: a 19-digit probe passes `is_num`, ERRORS every `[ -lt ]` (an errored test is false), and
# OPENS the gate. Both were live defects in this file. `sysctl` is the only seam that drives the
# REAL probe expression, so it is faked here and removed after.
for probe in 0 abc "" 999999999 1844674407470955161 9223372036854775807 99999999999999999999; do
  printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "hw.ncpu" ] && { echo "%s"; exit 0; }\nexit 1\n' "$probe" > "$TMP/bin/sysctl"
  chmod +x "$TMP/bin/sysctl"
  got="$(env -u MAX_LOAD PATH="$TMP/bin:$PATH" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
  # ⛔ THE ASSERTION IS EXACT, NOT A DIGIT-COUNT (P1, review round 2026-10-15, second pass). An
  # earlier version only required a non-zero value of at most 9 digits — and a WRAPPED 19-digit
  # probe yields 999999994, which satisfies every one of those properties while making the gate
  # INERT. A garbage probe must fall back to the DOCUMENTED DEFAULT, so that is what is asserted.
  # ⚠️ THE INVARIANT, EXACTLY, because an earlier comment generalised one digit past what it verifies:
  # a probe that is NON-NUMERIC, ZERO, or whose derivation produces TEN OR MORE digits falls back to
  # 40. A 1–9 digit probe is a PLAUSIBLE core count and is accepted verbatim — so `hw.ncpu=99999999`
  # still yields an INERT ceiling of 999999990 in ALL THREE copies that derive it (this file,
  # orch-loop.sh, install.sh). That is a SHARED residual, recorded in port-provenance.txt; the durable
  # fix is a plausibility bound on the core count, which the held copies must adopt together.
  [ "$got" = "40" ]; rc=$?
  ck "a core probe of '$probe' falls back to the default ceiling 40 (got MAX_LOAD=${got:-<empty>})" $rc
done
# ... and the fallback must not have REPLACED the derivation: a plausible probe still yields 10 x it.
# Without this pair, hardcoding the default would satisfy the loop above.
printf '#!/bin/sh\n[ "$1" = "-n" ] && [ "$2" = "hw.ncpu" ] && { echo 8; exit 0; }\nexit 1\n' > "$TMP/bin/sysctl"
got="$(env -u MAX_LOAD PATH="$TMP/bin:$PATH" bash -c '. "$1"; printf "%s" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "80" ]; rc=$?
ck "a plausible core probe of 8 still DERIVES 10 x it — the fallback did not become the value (got '${got:-<none>}')" $rc
rm -f "$TMP/bin/sysctl"
rm -f "$TMP/bin/sysctl"
# ... and the repair must not swallow the operator's DELIBERATE "spawn nothing": MAX_LOAD=0 is
# legal (`[ 0 -lt 0 ]` is false), and conflating it with a failed probe would stop a box that was
# told to stop. The check requires the helper to have ACTUALLY sourced (`type -t is_limit`): without
# that, an exported `MAX_LOAD=0` prints "0" on its own and the check passes on a tree with no
# spawn-gate.sh at all — which is exactly how it survived the pre-port non-vacuity run.
got="$(MAX_LOAD=0 bash -c '. "$1"; printf "%s/$(type -t is_limit)" "$MAX_LOAD"' _ "$GATE" 2>/dev/null)"
[ "$got" = "0/function" ]; rc=$?
ck "MAX_LOAD=0 survives coercion as 'spawn nothing', helper sourced (want 0/function, got '${got:-<none>}')" $rc

# ── 5) can_spawn is a strict `<` on the reading it is GIVEN ─────────────────────
# The argument (never a global) is the point: merge-one.sh uses `L` for a LOG PATH, so a gate that
# read a global `$L` would compare "/…/logs/merge-42" against MAX_LOAD.
got="$(. "$GATE" 2>/dev/null; MAX_LOAD=10; r=""
       can_spawn 9  && r="${r}9+" || r="${r}9-"
       can_spawn 10 && r="${r}10+" || r="${r}10-"
       can_spawn 0  && r="${r}0+" || r="${r}0-"
       printf '%s' "$r")"
[ "$got" = "9+10-0+" ]; rc=$?
ck "can_spawn accepts <MAX_LOAD and refuses >=MAX_LOAD (got '${got:-<none>}')" $rc
# The EMPTY reading is a DELIBERATE fail-open: a load probe that fails must not stop all merging on
# the box. Asserted rather than left implicit, because an unguarded default in a gate reads exactly
# like an oversight — and "fixing" it into a fail-closed gate would be the worse trade.
got="$(. "$GATE" 2>/dev/null; MAX_LOAD=10; r=""
       can_spawn "" && r="${r}empty+" || r="${r}empty-"
       can_spawn    && r="${r}noarg+" || r="${r}noarg-"
       printf '%s' "$r")"
[ "$got" = "empty+noarg+" ]; rc=$?
ck "a failed load reading (empty / no argument) is ALLOWED — the documented fail-open (got '${got:-<none>}')" $rc

# ── 6) run_agent REFUSES above the ceiling — and the agent is really not started ─
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
echo "PI_RAN" >> "$PI_LOG"
exit 0
PI
chmod +x "$TMP/bin/pi"

# drive <load> <label> [<max-load>] — runs the SHIPPED run_agent under a controlled reading. `load1`
# is re-declared AFTER sourcing, which is the seam described at the top. `pi` is a stub; every
# assertion is on WHETHER IT RAN and on the ledger, never on a model.
drive() { # drive <load> <label> <max-load>
  local load="$1" label="${2:-test agent}" max="${3:-10}"
  : > "$PI_LOG"
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" bash -c '
    . "$1"
    LOAD="$2"; MAX_LOAD="$3"; LOG="$4"; PROMPT="$5"; LABEL="$6"
    load1() { printf "%s" "$LOAD"; }
    run_agent 1 "$LOG" "$PROMPT" "$LABEL" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$load" "$max" "$LOG" "$PROMPT" "$label"
}

rm -f "$TMP/O/state/walltime.tsv"; : > "$LOG"
# ⛔ POSITIVE CONTROL, FIRST. The two negative assertions below — "the model was NOT invoked" and
# "no walltime row" — are the exact shape that passes VACUOUSLY on a tree where nothing exists: on
# the pre-port commit they were 2 of the only 2 checks that still reported ok. A negative assertion
# is evidence only once the machinery it denies has been shown to WORK, so the allowed run comes
# first and its result is ANDed into both checks.
ctl="$(drive 3)"
rows_allow=0
[ -s "$TMP/O/state/walltime.tsv" ] && rows_allow="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
ctl_ok=1
[ "$ctl" = "rc=0 started=1" ] && [ "$rows_allow" -ge 1 ] && ctl_ok=0
ck "POSITIVE CONTROL: below the ceiling the agent RUNS and the walltime sink records it ($ctl, rows=$rows_allow)" $ctl_ok

: > "$LOG"
res="$(drive 40)"
[ "$res" = "rc=75 started=0" ]; rc=$?
ck "run_agent above MAX_LOAD returns AGENT_LOAD_REFUSED and sets AGENT_STARTED=0 ($res)" $rc
{ [ "$ctl_ok" -eq 0 ] && [ ! -s "$PI_LOG" ]; }; rc=$?
ck "the model was NOT invoked on a refusal (spawn proven live by the control above)" $rc
# The refusal is EXPLICIT and NAMES the load: an operator reading the log must be able to tell it
# apart from a failed agent, because the two demand opposite responses (wait vs fix).
grep -q 'load-gate.*REFUSED.*load=40 >= max_load=10' "$LOG"; rc=$?
ck "the refusal line names the gate, the load and the ceiling" $rc
# A refused spawn must add NO walltime row: no agent ran, so a row would fabricate a zero-duration
# sample into the very series #1709 reads to size the fleet. Asserted as UNCHANGED-from-a-nonzero
# baseline, not as "empty" — "empty" is what a tree with no sink at all also produces.
rows_now=0
[ -s "$TMP/O/state/walltime.tsv" ] && rows_now="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
{ [ "$ctl_ok" -eq 0 ] && [ "$rows_now" = "$rows_allow" ]; }; rc=$?
ck "a refusal appends NO walltime row — the #1709 series stays honest (rows=$rows_now, $rows_allow before)" $rc

# ── 7) ... and it STARTS below the ceiling, recording the measurement ────────────
: > "$LOG"
res="$(drive 3)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "run_agent below MAX_LOAD starts the agent ($res)" $rc
grep -q 'PI_RAN' "$PI_LOG"; rc=$?
ck "the model was actually invoked when the gate allowed it" $rc
grep -q 'elapsed=' "$LOG"; rc=$?
ck "the run records the measured elapsed wall-time (#1709 item 3)" $rc
# 6 tab-separated fields: epoch, kind, tag, wall limit, elapsed, rc — the append-only series.
# (drive() passes a wall limit of 1, so field 4 is 1: the row must carry the LIMIT THAT WAS ASKED
# FOR, not a default — that is what makes it a usable measurement.)
row="$(tail -1 "$TMP/O/state/walltime.tsv" 2>/dev/null)"
nf="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
f4="$(printf '%s' "$row" | cut -f4)"
f5="$(printf '%s' "$row" | cut -f5)"
[ "$nf" = "6" ] && [ "$f4" = "1" ]; rc=$?
ck "a started run appends one 6-field row to walltime.tsv carrying the ASKED-FOR limit (got: ${row:-<none>})" $rc
# ⛔ PRESENT IS NOT MEASURED (P3, review round 2026-10-15). `grep -q 'elapsed='` plus NF=6 passes on a
# tree whose telemetry regressed to the literal `elapsed=garbage`, and #1709 exists precisely because
# wall-time was unmeasured. So assert the VALUE is a non-negative integer.
case "$f5" in ''|*[!0-9]*) rc=1 ;; *) rc=0 ;; esac
ck "the recorded elapsed is a non-negative INTEGER, not merely present (f5='${f5:-<empty>}')" $rc

# ── 8) the gate RE-READS at the spawn, and a refusal is not a `pi` exit status ───
# This is the whole point of the port: a chain-<N> worker dispatched on a quiet box may open its PR
# 90 minutes later, and the reading that governs is the one taken at the spawn.
got="$(PATH="$TMP/bin:$PATH" O="$TMP/O" bash -c '
  . "$1"
  MAX_LOAD=10
  load1() { printf "2"; }                   # the controller-time reading: quiet
  can_spawn "$(load1)" || exit 9            # would have allowed the session
  load1() { printf "99"; }                  # load has since spiked
  run_agent 5 "$2" "$3" "late chain worker" >/dev/null 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$TMP/log2" "$PROMPT" 2>/dev/null)"
[ "$got" = "rc=75" ]; rc=$?
ck "a spawn re-reads load (quiet dispatch, spiked spawn -> refused: '${got:-<none>}')" $rc
# ... and pi's 0-255 namespace cannot be mistaken for a refusal, so AGENT_STARTED (not the exit
# code) is what the callers act on.
# ⛔ THE STUB MUST ACTUALLY EXIT 75 (P1, review round 2026-10-15). The first version of this
# check passed the LABEL "agent that itself exits 75" to the ONE stub `pi`, which exits 0 — so
# the check held whatever the code did. Proven vacuous by mutation: replacing the pre-launch
# `AGENT_STARTED=1` with a post-`wait` derivation from `rc == AGENT_LOAD_REFUSED` left the suite
# at 42 passed, 0 failed. Under that mutation a real `pi` that exits 75 makes fix-one.sh REFUND a
# booked attempt and SKIP the merge-chain re-run for a fixer that actually ran, so this must
# assert BOTH the status and the flag against a stub that really exits 75.
mkdir -p "$TMP/bin75"
printf '#!/bin/sh\nexit 75\n' > "$TMP/bin75/pi"
chmod +x "$TMP/bin75/pi"
got="$(PATH="$TMP/bin75:$TMP/bin:$PATH" O="$TMP/O" bash -c '
  . "$1"
  load1() { printf "0"; }
  MAX_LOAD=10
  run_agent 1 "$2" "$3" "pi that exits 75 itself" >/dev/null 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$GATE" "$TMP/log3" "$PROMPT" 2>/dev/null)"
[ "$got" = "rc=75 started=1" ]; rc=$?
ck "a pi that itself exits 75 is reported STARTED, not as a load refusal (want rc=75 started=1, got '${got:-<none>}')" $rc

# ── 9) the PORTED CALLERS: a refusal must not consume a fixer attempt ───────────
# The headline behavioural claim of this port is fix-one.sh's REFUND. orch-loop.sh books the attempt
# (fixcount+1) and DELETES the findings marker when it CREATES the session — UPSTREAM of the gate
# inside run_agent — so without the refund three refusals reach MAX_FIX_TRIES and the PR is PARKED
# "needs a human" having never had a single fixer run. Sections 1–8 drive the helper; NOTHING above
# drives a caller, so the refund — and the exit-status contract of adopt-fix/chain-merge/lane —
# would ship unpinned. These checks run the REAL scripts as subprocesses against a throwaway repo.
#
# MAX_LOAD=0 is the refusal lever: `[ "$l" -lt 0 ]` is false for every reading, so it refuses
# deterministically with no PATH games, and it is a legal operator value (pinned just above).
RIG="$TMP/rig"; RREPO="$RIG/repo"; RO="$RIG/O"
mkdir -p "$RIG/bin" "$RO/logs" "$RO/state" "$RREPO"
git -C "$RREPO" init -q -b main
git -C "$RREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$RREPO" branch work
git -C "$RREPO" branch adoptbranch   # adopt-fix gets its OWN branch: `work` is already checked out
                                   # in .worktrees/fix-7 above, and git refuses to check it out twice.
git -C "$RREPO" worktree add -q .worktrees/fix-7 work
# The stub agent, and a merge-one.sh stub that RECORDS its invocation: "a refusal does not re-run the
# merge chain" is only testable if the chain's invocation is observable.
printf '#!/bin/sh\necho PI_RAN >> "$PI_LOG"\nexit 0\n' > "$RIG/bin/pi"
printf '#!/bin/sh\necho MERGE_ONE_RAN >> "$MERGE_LOG"\nexit "${MERGE_RC:-0}"\n' > "$RO/merge-one.sh"
printf '#!/bin/sh\nexit 1\n' > "$RIG/bin/gh"
chmod +x "$RIG/bin/pi" "$RIG/bin/gh" "$RO/merge-one.sh"
# `gh` is stubbed to FAIL: an empty `gh pr view` head SKIPS fix-one.sh's cross-box claim block, so
# these checks exercise the gate and the refund, not the claim machinery (which has its own suite).
fix_argv() { printf '%s\n%s\n%s\nwork\n' "$RREPO" "daniel-ospina/agent-infra" 7 > "$RIG/argv7"; }

fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; frc=$?
got="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$frc" -eq 75 ] && [ "$got" = "1" ]; }; rc=$?
ck "fix-one.sh --argv (CONTROLLER) on a refused load exits 75 and REFUNDS fixcount 2->1 (rc=$frc, fixcount=${got:-<gone>})" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a refused fixer starts no agent and does NOT re-run the merge chain" $rc

# ... and the MANUAL path must refund NOTHING: it never incremented the counter, so refunding would
# hand the controller a free attempt and the count would drift down forever.
printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; frc=$?
got="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$frc" -eq 75 ] && [ "$got" = "2" ]; }; rc=$?
ck "fix-one.sh (MANUAL/positional) refunds nothing — fixcount stays 2 (rc=$frc, fixcount=${got:-<gone>})" $rc

# POSITIVE CONTROL for the pair above: with the gate OPEN the fixer runs AND the chain is re-run.
# Without it, "no agent ran" and "the chain was not re-run" would pass on any broken invocation.
# FIX_TIMEOUT=5 keeps the suite's own footprint honest: run_agent's watchdog subshell leaves its
# `sleep` reparented (a disclosed, pre-existing defect), so the default 2400 would park a 40-minute
# process per suite run. A small limit bounds the leak to seconds without changing what is proven.
: > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; frc=$?
{ [ "$frc" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG"; }; rc=$?
ck "POSITIVE CONTROL: gate open -> the fixer RUNS and the merge chain IS re-run (rc=$frc)" $rc

# ── 10) the WRAPPERS propagate the status ───────────────────────────────────────
# adopt-fix.sh and chain-merge.sh are report-then-`echo` scripts: their LAST command used to be a
# reporting `echo`, so `$?` was echo's — always 0 — and a wrapper doing `… && next` took the SUCCESS
# branch whatever happened. Drive each and read the EXIT CODE.
# ⛔ AND DRIVE MORE THAN ONE CODE (P2, review round 2026-10-15, second pass). A 75-only assertion is
# satisfied by a wrapper that HARDCODES 75 — which would report a crash as a load refusal and make the
# controller re-dispatch for ever. The property under test is PROPAGATION, so 0 and 1 are driven too.
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/chain-merge.sh" "$HERE/adopt-fix.sh" "$RO/"
# chain-merge.sh waits up to 90 min for a PR, so `gh pr list` must answer on the FIRST poll.
printf '#!/bin/sh\ncase "$1 $2" in "pr list") echo 7 ;; *) exit 1 ;; esac\n' > "$RIG/bin/gh"
chmod +x "$RIG/bin/gh"
# ⛔ THE STUB'S STATUS IS A DELIBERATE STAND-IN, NOT A CLAIM ABOUT merge-one.sh: the shipped
# merge-one.sh ends on a reporting `echo` and contains no `exit 75` (0 hits), so it returns 0 on the
# paths that reach its end. Its early guards DO exit 1/2/3/4, and those propagate through this wrapper
# today; the 75 arm is forward-looking until the blocked #8521 half lands in merge-one.sh. That
# residual is recorded in port-provenance.txt — this check pins the WRAPPER, which is what changed.
for want in 0 1 75; do
  : > "$MERGE_LOG"
  ( cd "$RREPO" && O="$RO" MERGE_RC="$want" PATH="$RIG/bin:$PATH" \
      bash "$HERE/chain-merge.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; crc=$?
  [ "$crc" -eq "$want" ]; rc=$?
  ck "chain-merge.sh propagates merge-one.sh's status $want (got $crc) — not a constant" $rc
done
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc=$?
[ "$arc" -eq 75 ]; rc=$?
ck "adopt-fix.sh exits with the FIXER's status (75 on a load refusal), not echo's 0 (rc=$arc)" $rc
# ... and the SUCCESS arm too: a constant-75 wrapper would pass the line above and report every
# successful adopt as a refusal.
: > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc0=$?
{ [ "$arc0" -eq 0 ] && grep -q PI_RAN "$PI_LOG"; }; rc=$?
ck "adopt-fix.sh reports 0 when the fixer RAN and succeeded (got $arc0) — not a constant" $rc

: > "$MERGE_LOG"


# lane.sh: the third ported caller. Assert it gets as far as the spawn (the prompt is written) and
# then refuses WITHOUT starting an agent — the whole point, since lane.sh is what opens the PR.
: > "$PI_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc=$?
{ [ "$lrc" -eq 75 ] && [ ! -s "$PI_LOG" ] && [ -s "$RO/logs/prompt-9999.txt" ]; }; rc=$?
ck "lane.sh on a refused load exits 75, writes the prompt, and NEVER spawns (rc=$lrc)" $rc

# ── 11) a suite nothing RUNS is not a gate ──────────────────────────────────────
# This file is not yet a registered CI shard: scripts/run-bash-shards.sh is held by concurrent lanes
# (PR #1769/#1730), so the entry cannot be added from here. The problem is SILENCE — a suite that is
# present but unwired gets forgotten. So the residual is asserted as an EQUALITY: exactly one
# orchestrator-harness suite is unwired, and it is this one. Wiring it turns this red until it is
# moved to the empty-want arm; adding a SECOND unwired suite turns it red too.
SHARDS="$(cd "$HERE/.." && pwd)/run-bash-shards.sh"
unwired=""
for f in "$HERE"/*.test.sh; do
  b="$(basename "$f")"
  grep -q "$b" "$SHARDS" 2>/dev/null || unwired="$unwired $b"
done
unwired="${unwired# }"
[ "$unwired" = "spawn-gate.test.sh" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      unwired suites: [${unwired:-<none>}]"
ck "the only orchestrator-harness suite NOT wired into run-bash-shards.sh is this one [$unwired]" $rc

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
