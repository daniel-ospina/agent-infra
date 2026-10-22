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
# A here-string, NOT `printf | grep -q`: `grep -q` exits on first match, `printf` takes SIGPIPE, and
# under `pipefail` the pipeline returns 141 — so the idiom reads as "no match" ON A MATCH, which is
# precisely the false negative this check exists to catch (scripts/check-no-sigpipe-grep.sh, #841).
{ [ "$nrc" -eq 78 ] && grep -q 'FATAL' <<<"$out"; }; rc=$?
ck "lane.sh truly REFUSES (exit 78 + FATAL) with no helper beside it — driven, not grepped (rc=$nrc)" $rc
# fix-one.sh takes FOUR positional args, and PR must be numeric or it bails at its FIRST guard
# (exit 1) and never reaches the source line — which would make this check pass for the wrong reason.
out="$( ( cd "$NX" && O="$NX/O" bash "$NX/fix-one.sh" "$NX" daniel-ospina/agent-infra 7 work ) 2>&1 )"; nrc=$?
{ [ "$nrc" -eq 78 ] && grep -q 'FATAL' <<<"$out"; }; rc=$?
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
  # STATED LIMITS, all three (a limit nobody writes down is a limit the next lane rediscovers):
  #   (1) an invocation that omits `--no-session` (the harness convention requires it);
  #   (2) one that omits the PRINT-MODE FLAG (`pi --no-session …`) — the detector keys on the flag
  #       PAIR, not on `--no-session` alone; and
  #   (3) one whose command name AND flags are both assembled at runtime.
  # Those residues are the runtime `run_agent` contract's job, not a grep's. SCOPE: `scripts/` only —
  # `extensions/` also launches `pi` and is outside this guard's declared population. It can also
  # FALSE-POSITIVE on a non-launcher carrying a `-p` token and a `--no-session` mention, which fails
  # CLOSED (RED, and the file is named), so it cannot hide a launch path.
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
# `scripts/review-pr.sh` is DECLARED here for the same reason (#2288): it spawns the fresh-context
# reviewer that produces the merge artifact. It carries the bound run_agent() would give it (its own
# wall-clock watchdog), the SAME posture merge-one.sh's reviewer has — the installed `pi` shim is the
# load gate at the spawn point, and its rc=76 refusal is handled explicitly (exit 75, nothing
# consumed) — but no load gate of its OWN, so it belongs in this list by name, not silently.
EXPECTED_PI_TREE="scripts/cloud-cell-bringup.sh scripts/orchestrator-harness/merge-one.sh scripts/orchestrator-harness/spawn-gate.sh scripts/review-pr.sh"
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
  # DISK_MIN_FREE_MB=1 so these LOAD checks cannot be decided by this host's free space — the disk
  # gate runs first now (that ordering is itself pinned below), so on a genuinely full CI box the
  # load-refusal assertions would otherwise come back 77 and read as a load-gate regression.
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 bash -c '
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
# ⛔ THE FILE STUB ALONE IS NOT ENOUGH FOR THESE ARMS, AND WHAT IT PRODUCES IS THE WORST KIND OF
# FAILURE (P1, found 2026-10-16 while fixing #1828, reproduced live). Every caller this section
# drives runs `export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH`, which puts a SYSTEM `pi` AHEAD
# of $RIG/bin — so on any box that has one (this cell has /usr/local/bin/pi) the file stub was
# SHADOWED and the arm tested nothing. Two consequences, both silent in the direction that matters:
#   • the positive controls' `grep PI_RAN` failed against an empty log — a false RED that reads
#     as a broken gate rather than as a shadowed stub; and
#   • worse, the arm INVOKED THE REAL AGENT (a full pi session against the fix-7 prompt), so a
#     test run spent model tokens and wrote into the operator's session/logs.
# A shell FUNCTION is resolved BEFORE any PATH lookup, so it cannot be shadowed by the caller's
# PATH edit; the stub is therefore defined as an exported function as well as a file. The file stub
# is KEPT because it is what the pre-export `drive` checks above resolve — and because dropping the
# `export -f` below costs a RED control (fail-closed), never another silently-real agent.
pi() { echo PI_RAN >> "$PI_LOG"; return 0; }
export -f pi
# ...and pin the MECHANISM, not only its effect: the whole fix rests on the function surviving into
# the callers' environment, so assert it is there BY NAME. Otherwise a future edit that drops the
# `export -f` resurfaces as a confusing positive-control red instead of naming its own cause.
env | grep -q '^BASH_FUNC_pi' ; rc=$?
ck "the rig's pi stub is EXPORTED into the callers' environment (a function beats the callers' PATH prepend)" $rc
# `gh` is stubbed to FAIL: an empty `gh pr view` head SKIPS fix-one.sh's cross-box claim block, so
# these checks exercise the gate and the refund, not the claim machinery (which has its own suite).
fix_argv() { printf '%s\n%s\n%s\nwork\n' "$RREPO" "daniel-ospina/agent-infra" 7 > "$RIG/argv7"; }

# ⛔ EVERY LOAD/SUCCESS ARM BELOW PINS DISK_MIN_FREE_MB=1, AND IT IS NOT COSMETIC (review round 2, P1).
# The disk gate runs FIRST, so without this the arms are decided by THIS HOST's free space: on a box
# with less than the shipped 500 MiB floor — the exact state this PR exists for — each of them gets
# AGENT_DISK_REFUSED=77 instead of the 75/0 it asserts, and six "load-gate regressions" are reported
# that are not regressions. `drive()` above neutralises the disk gate for the same reason and says so;
# the arms that drive the real CALLERS must do it too. Only the arm that INTENDS a disk refusal varies
# the floor (it sets DISK_MIN_FREE_MB=9999999).
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; frc=$?
got="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$frc" -eq 75 ] && [ "$got" = "1" ]; }; rc=$?
ck "fix-one.sh --argv (CONTROLLER) on a refused load exits 75 and REFUNDS fixcount 2->1 (rc=$frc, fixcount=${got:-<gone>})" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a refused fixer starts no agent and does NOT re-run the merge chain" $rc
# ⛔ THE LOAD DIRECTION IS NAMED TOO (review round 2, P2). The disk arm below asserts the disk wording
# is present; on its own that is satisfied by a caller which prints the DISK wording for EVERY refusal,
# and that caller would send an operator to reclaim disk on a box whose only problem is load. Both
# directions have to be pinned, or the pair proves nothing about the naming.
grep -q 'fixer NOT started (load gate' "$RO/logs/fix-7.log"; rc=$?
ck "fix-one.sh NAMES the load gate on a load refusal — the disk wording is not universal" $rc

# ⛔ A STALE $O HELPER MUST NOT TURN A REFUSAL INTO A LOST ATTEMPT (review round 2, P1 — REPRODUCED).
# The daemon executes `$O/<script>` and $O is seeded file by file, so a NEW caller can run against a
# PRE-#1765 helper that defines AGENT_LOAD_REFUSED but NOT AGENT_DISK_REFUSED. Under `set -u` the
# caller's `[ "$ar" = "$AGENT_DISK_REFUSED" ]` then aborts BEFORE its refund — measured on the
# pre-fix tree: `bash: AGENT_DISK_REFUSED: unbound variable`, rc=1, fixcount left at 2 (no refund).
# The fixture is derived FROM THE SHIPPED HELPER (only the constant's definition is removed), so it
# tracks the file under test instead of re-implementing a pre-fix helper by hand.
mkdir -p "$RIG/stale"
cp "$HERE/fix-one.sh" "$RIG/stale/"
sed -e 's/^AGENT_DISK_REFUSED=77$/# STALE PRE-#1765 HELPER: this constant does not exist/' \
    -e 's/return "\$AGENT_DISK_REFUSED"/return 77/' \
    "$HERE/spawn-gate.sh" > "$RIG/stale/spawn-gate.sh"
# The transformation is ASSERTED, not assumed: if the helper stops matching those patterns the sed
# yields an UNCHANGED file and the arm below would pass for the wrong reason.
grep -q 'AGENT_DISK_REFUSED=' "$RIG/stale/spawn-gate.sh"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and the stale-helper fixture really carries no AGENT_DISK_REFUSED (the sed transformed it)" $rc
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$RIG/stale/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; src_=$?
sgot="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$src_" -eq 75 ] && [ "$sgot" = "1" ]; }; rc=$?
ck "a STALE helper still REFUNDS a load refusal: rc=75, fixcount 2->1 (rc=$src_, fixcount=${sgot:-<gone>})" $rc

# ... and the DISK refusal through the SAME caller (#1765). 77, refunded the same way — and, the
# point of the arm, it must NAME the disk gate. The two refusals demand OPPOSITE remedies (wait for
# the load to fall vs reclaim space), so a disk refusal reported as a load refusal sends an operator
# to wait for an event that cannot arrive.
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; drc=$?
dgot="$(cat "$RO/state/fixcount-7" 2>/dev/null)"
{ [ "$drc" -eq 77 ] && [ "$dgot" = "1" ]; }; rc=$?
ck "fix-one.sh --argv on a DISK refusal exits 77 and REFUNDS the attempt (rc=$drc, fixcount=${dgot:-<gone>})" $rc
grep -q 'fixer NOT started (disk gate' "$RO/logs/fix-7.log"; rc=$?
ck "fix-one.sh NAMES the disk gate on a disk refusal (not the load gate)" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a disk-refused fixer starts no agent and does NOT re-run the merge chain" $rc

# ... and the MANUAL path must refund NOTHING: it never incremented the counter, so refunding would
# hand the controller a free attempt and the count would drift down forever.
printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
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
rows_d0=0; [ -s "$RO/state/disk.tsv" ] && rows_d0="$(wc -l < "$RO/state/disk.tsv" | tr -d ' ')"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; frc=$?
{ [ "$frc" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG"; }; rc=$?
ck "POSITIVE CONTROL: gate open -> the fixer RUNS and the merge chain IS re-run (rc=$frc)" $rc
# ⛔ THE ALLOWED RUN MUST RECORD ITS READING TOO (review round 2, P2). run_agent writes disk.tsv "for
# ALLOWED runs too — a series that only records refusals cannot answer 'how close did we get'"
# (spawn-gate.sh). Only the REFUSAL row was asserted, so moving that write inside the refusal branch
# would leave the series refusal-only and this suite still green — the documented contract silently
# gone. Assert the series GROWS by one on an allowed spawn, as the walltime checks do.
rows_d1=0; [ -s "$RO/state/disk.tsv" ] && rows_d1="$(wc -l < "$RO/state/disk.tsv" | tr -d ' ')"
[ "$rows_d1" = "$(( rows_d0 + 1 ))" ]; rc=$?
ck "an ALLOWED run appends its own disk.tsv row, not only a refusal ($rows_d1 vs $rows_d0 before)" $rc
# ⛔ AND IT RECORDS THE VOLUME THE AGENT ACTUALLY OCCUPIES (review round 2, P2 — the fix for a real
# mis-measurement). fix-one.sh does `cd "$REPO"`, so the gate's `:-$PWD` default would be the MAIN
# CHECKOUT while the fixer works in $WT; it now passes `DISK_GATE_PATH="$WT"` explicitly. The ledger
# is where that is observable: the disk arms set DISK_GATE_PATH themselves, so without this assertion
# the explicit path could be dropped from fix-one.sh and every other check here would still pass.
dp="$(tail -1 "$RO/state/disk.tsv" 2>/dev/null | cut -f5)"
# ⛔ COMPARED BY PHYSICAL PATH, NOT BY STRING (macOS portability — this check was RED on every macOS
# box while GREEN on the Linux cell, i.e. it could not be reproduced where it was written). The two
# sides are produced by DIFFERENT tools with different ideas of the same directory: `$WT` comes from
# `git worktree list --porcelain`, which prints the REALPATH (`/private/var/folders/...`), while
# `$RREPO` is built from `mktemp -d`, which returns the logical form (`/var/folders/...`) — and on
# macOS `/var` IS a symlink into `/private/var`. So the raw comparison asserted a property about
# `$TMPDIR`'s spelling rather than the one it exists to assert. `pwd -P` on BOTH sides asks the real
# question: "are these the same DIRECTORY?". The mismatch is still red (a realpath is unique), so
# nothing is loosened — only the false red goes away.
dp_p="$(cd "$dp" 2>/dev/null && pwd -P)"; wt_p="$(cd "$RREPO/.worktrees/fix-7" 2>/dev/null && pwd -P)"
[ -n "$dp_p" ] && [ "$dp_p" = "$wt_p" ]; rc=$?
ck "the fixer's disk reading is the WORKTREE volume, not the main checkout (path='${dp:-<none>}')" $rc

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
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=0 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc=$?
[ "$arc" -eq 75 ]; rc=$?
ck "adopt-fix.sh exits with the FIXER's status (75 on a load refusal), not echo's 0 (rc=$arc)" $rc
# ... and the LOAD wording is named here too: the disk arm below must not be satisfiable by a wrapper
# that reports the DISK remedy for a load refusal (review round 2, P2).
grep -q 'fixer NOT started (load gate)' "$RO/logs/adopt-7.log"; rc=$?
ck "adopt-fix.sh NAMES the load gate on a load refusal" $rc
# ... and the SUCCESS arm too: a constant-75 wrapper would pass the line above and report every
# successful adopt as a refusal.
: > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc0=$?
{ [ "$arc0" -eq 0 ] && grep -q PI_RAN "$PI_LOG"; }; rc=$?
ck "adopt-fix.sh reports 0 when the fixer RAN and succeeded (got $arc0) — not a constant" $rc
# The DISK arm of the same wrapper: 77 must PROPAGATE too, and be named. A 75-only mapping would
# report a full filesystem as "wait for the load to fall" — a remedy that cannot ever work.
printf '3\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc2=$?
[ "$arc2" -eq 77 ]; rc=$?
ck "adopt-fix.sh propagates the DISK refusal 77 (got $arc2) — not normalised to a load refusal" $rc
grep -q 'DISK gate' "$RO/logs/adopt-7.log"; rc=$?
ck "adopt-fix.sh names the DISK gate on a disk refusal" $rc

: > "$MERGE_LOG"


# lane.sh: the third ported caller. Assert it gets as far as the spawn (the prompt is written) and
# then refuses WITHOUT starting an agent — the whole point, since lane.sh is what opens the PR.
: > "$PI_LOG"; : > "$RO/logs/lane-9999.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc=$?
{ [ "$lrc" -eq 75 ] && [ ! -s "$PI_LOG" ] && [ -s "$RO/logs/prompt-9999.txt" ]; }; rc=$?
ck "lane.sh on a refused load exits 75, writes the prompt, and NEVER spawns (rc=$lrc)" $rc
grep -q 'load gate refused' "$RO/logs/lane-9999.log"; rc=$?
ck "lane.sh NAMES the load gate on a load refusal" $rc
# The DISK arm: 77 propagates out of lane.sh, and the refusal line NAMES the disk gate. lane.sh is
# what opens a PR, so a lane refused here consumed nothing — but an operator told "load gate" would
# re-dispatch into the same full filesystem for ever.
: > "$PI_LOG"; : > "$RO/logs/lane-9999.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
    PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc2=$?
[ "$lrc2" -eq 77 ]; rc=$?
ck "lane.sh on a DISK refusal exits 77 (got $lrc2) — not reported as a load refusal" $rc
grep -q 'DISK gate refused' "$RO/logs/lane-9999.log"; rc=$?
ck "lane.sh NAMES the disk gate on a disk refusal" $rc

# ── 11) the DISK gate (#1765) ─────────────────────────────────────────────
# The measured incident: pi-lane-1 hit 100% twice — 2026-10-15 (`/dev/root 32G, 30G used, 0 avail`,
# every git op failing) and 2026-10-16 05:13Z, when the controller died writing its own log
# (`orch-loop.sh: echo: write error: No space left on device`). The gate's job is to refuse to START
# an agent on a filesystem that cannot run one: `pi` has no disk limit of its own, so this is the
# last point at which the consumption can still be stopped.
#
# ⛔ NO SEAM IS STUBBED BELOW. `disk_free_mb` is the shipped `df -Pk` probe and DISK_GATE_PATH /
# DISK_MIN_FREE_MB / DISK_WARN_FREE_MB are the shipped env overrides, so every check drives the real
# predicate against a real filesystem. A stubbed probe would prove only that a branch exists.
drive_disk() { # drive_disk <path> <floor-mb> [<warn-mb>]
  local path="$1" floor="$2" warn="${3:-}"
  : > "$PI_LOG"
  # MAX_LOAD=999999999 so these DISK checks cannot be decided by this host's 1-min load: `drive_disk`
  # does NOT stub `load1` (the disk gate is the subject and it runs first), so without this the
  # section would go red on a busy box — and its own POSITIVE CONTROL with it. A test that fails for
  # a reason unrelated to its subject is worse than no test: it teaches the reader to ignore red.
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$path" DISK_MIN_FREE_MB="$floor" DISK_WARN_FREE_MB="$warn" \
  bash -c '
    . "$1"
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "disk gate test" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT"
}

# POSITIVE CONTROL, FIRST — the file's own rule. On a tree with no disk probe at all the "refused"
# assertions below would ALL pass for the wrong reason, so the probe must be shown to answer first.
free_now="$(bash -c '. "$1"; disk_free_mb "$2"' _ "$GATE" "$TMP")"
case "$free_now" in ''|*[!0-9]*) rc=1 ;; *) [ "$free_now" -gt 0 ]; rc=$? ;; esac
ck "POSITIVE CONTROL: disk_free_mb reports a real free-MB integer for an existing path (${free_now:-<empty>}MB)" $rc
# ... and it must report NOTHING for a path it cannot read, rather than 0 — 0 is a CLAIM that the
# disk is full, and the fail-open case further down is vacuous unless "unreadable" really is empty.
nofree="$(bash -c '. "$1"; disk_free_mb "$2"' _ "$GATE" "$TMP/no-such-path-$$")"
[ -z "$nofree" ]; rc=$?
ck "... and reports NOTHING (not 0) for an unreadable path — 0 would be a claim the disk is full" $rc

# The polarity, in one place. Unreadable FAILS OPEN (#1702's documented posture: a broken probe must
# not stop the box for ever); a readable reading below the floor FAILS CLOSED.
pol="$(bash -c '. "$1"; DISK_MIN_FREE_MB=9999
  disk_ok ""    && a=allow || a=refuse
  disk_ok 9998  && b=allow || b=refuse
  disk_ok 9999  && c=allow || c=refuse
  disk_ok abc   && d=allow || d=refuse
  printf "%s %s %s %s" "$a" "$b" "$c" "$d"' _ "$GATE")"
[ "$pol" = "allow refuse allow allow" ]; rc=$?
ck "disk_ok: unreadable ALLOWS, one below the floor REFUSES, AT the floor allows, garbage ALLOWS ($pol)" $rc

# A 0 floor is a NO-OP GATE: `[ "$mb" -ge 0 ]` is true for every reading, so it could never refuse.
zf="$(DISK_MIN_FREE_MB=0 bash -c '. "$1"; printf "%s" "$DISK_MIN_FREE_MB"' _ "$GATE")"
[ "$zf" = "500" ]; rc=$?
ck "a 0 floor is REPAIRED, not honoured — a gate that can never refuse is not a gate (got '$zf')" $rc
# ⛔ AND THE REPAIRED DEFAULT MUST EQUAL `cloud-cell-supervisor.sh`'s OWN FLOOR (review round 1, P1).
# That file's `cmd_check` answers "can this cell run a controller?" against `MIN_FREE_MB`, INDEPENDENTLY
# of this gate. A DISPATCH floor above it opens a band — [supervisor floor, dispatch floor) — where
# `check` prints `CELL CAN RUN A CONTROLLER` and every lane spawn is then refused 77: an instrument
# reporting healthy about a cell that can do no work, i.e. a FALSE PASS, which is why "a higher floor
# is safer" is the wrong instinct here. Pin the EQUALITY against that file's own line rather than
# against the literal 500, so raising ONE of the two alone reddens this instead of drifting silently.
sup="$(sed -n 's/^MIN_FREE_MB="\${MIN_FREE_MB:-\([0-9][0-9]*\)}".*/\1/p' "$HERE/../cloud-cell-supervisor.sh" 2>/dev/null | head -1)"
# ⛔ AND THE DEFAULT MUST BE PROBED WITH THE VARIABLE **UNSET** (verification round, P1 — this check
# was FAIL-OPEN as first written). Driving `DISK_MIN_FREE_MB=0` exercises the REPAIR constants, NOT
# the default on the assignment line: patching ONLY that line `500` -> `600` left the whole suite
# GREEN while the live default was 600 against the supervisor's 500 — the exact drift the pin exists to
# catch, in the direction that matters. `env -u` removes the variable from a caller's environment too,
# so the probe reads the shipped default and nothing else. (The pre-fix count is deliberately NOT
# recorded: it is not re-measurable from this tree without reverting the check below.)
dfl="$(env -u DISK_MIN_FREE_MB bash -c '. "$1"; printf "%s" "$DISK_MIN_FREE_MB"' _ "$GATE")"
if [ -n "$sup" ] && [ "$dfl" = "$sup" ]; then rc=0; else rc=1; fi
ck "the DEFAULT (unset) floor EQUALS the supervisor's MIN_FREE_MB ($dfl vs ${sup:-<unreadable>}) — a higher one is a false PASS, not a safer gate" $rc
if [ -n "$sup" ] && [ "$zf" = "$sup" ]; then rc=0; else rc=1; fi
ck "...and the REPAIRED floor (DISK_MIN_FREE_MB=0) equals it too ($zf) — the fallback is not a second, drifting default" $rc
# ⛔ THE FREE-SPACE CONVERSION MUST NOT GO THROUGH `print int(...)` (review round 1, P2). `int()`
# renders through awk's OFMT, so on mawk — the default `awk` on Debian/Ubuntu, i.e. ON THE CELL — an
# integral value at or above 2^31 prints as `2.14748e+09`: not a number to `[ -lt ]` (errors), which
# `disk_ok` reads as garbage and ALLOWS, i.e. the gate FAILS OPEN on a nearly-full disk. Pinned BY
# NAME because the failure is awk-implementation-specific and this box has no mawk to drive — the same
# shape as the `export -f` mechanism pin in §11. ⚠️ Stated limit: a source-shaped check cannot see a
# conversion that is assembled at runtime; the behavioural half is the integer contract on
# `disk_free_mb` above, and `orch-loop.sh`'s sibling probe uses the identical idiom.
grep -qF 'printf "%d\n", $4 / 1024' "$GATE" && ! grep -qF 'print int($4 / 1024)' "$GATE"; rc=$?
ck "free-space MB is converted with printf %d, NOT print int() — int() prints 2.14748e+09 on mawk, which fails the gate OPEN" $rc

# A warn band BELOW the floor can never fire (the refusal wins first), which would silently degrade
# "warn before it is full" into "no warning at all".
wb="$(DISK_MIN_FREE_MB=500 DISK_WARN_FREE_MB=1 bash -c '. "$1"; printf "%s" "$DISK_WARN_FREE_MB"' _ "$GATE")"
[ "$wb" = "1000" ]; rc=$?
ck "a warn band below the floor is repaired to STRICTLY above it (got '$wb')" $rc
# ⛔ AND THE REPAIR IS PINNED BY BEHAVIOUR, NOT BY THAT VARIABLE (review round 1, P1). `>= floor` was
# the original repair, and with `warn == floor` the interval [floor, warn) is EMPTY — the refusal
# fires on `mb < floor`, the warning on `mb < warn`, so a repaired-to-the-floor band could never
# warn, i.e. the repair shipped the exact failure it existed to prevent while the value-only check
# above stayed green. Drive the SHIPPED predicate AT the floor: the gate must allow it AND warn.
band="$(DISK_MIN_FREE_MB=100 DISK_WARN_FREE_MB=1 bash -c '
  . "$1"
  disk_ok 100  && a=allow   || a=refuse
  disk_low 100 && b=warn    || b=nowarn
  disk_low 99  && c=warn    || c=nowarn
  printf "%s %s %s warn=%s" "$a" "$b" "$c" "$DISK_WARN_FREE_MB"' _ "$GATE")"
[ "$band" = "allow warn warn warn=200" ]; rc=$?
ck "AT the floor the gate ALLOWS and still WARNS — an empty band is not a warning ($band)" $rc
# ⛔ ONE READER FOR "IS THIS A NUMBER" (review round, P3). The announcement and the predicates must
# classify a reading IDENTICALLY, or the WARN reports a different verdict than the one it is
# announcing — and the divergence was a fail-OPEN, not a cosmetic one: `is_num` rejects a LEADING ZERO
# where the predicates' comparison accepts `0100` as 100, and because the WARN branch RETURNS before
# `disk_ok` runs, such a reading was ALLOWED where the previous form REFUSED it. Driven end to end
# through the shipped run_agent below — unreachable from the shipped probe, which is exactly why it
# needs a pin: the seam is reachable by any redeclared probe, and this suite redeclares one itself.
: > "$LOG"; : > "$PI_LOG"
lz="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 DISK_GATE_PATH="$TMP" \
  DISK_MIN_FREE_MB=500 bash -c '
    . "$1"
    disk_free_mb() { printf "%s" "0100"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "leading-zero probe" >/dev/null 2>&1
    printf "rc=%s started=%s warned=%s" "$?" "$AGENT_STARTED" \
      "$(grep -c "could not read free space" "$LOG")"' _ "$GATE" "$LOG" "$PROMPT")"
[ "$lz" = "rc=77 started=0 warned=0" ]; rc=$?
ck "a LEADING-ZERO reading is REFUSED like any other below-floor number ($lz) — an announcer that disagrees is a fail-open" $rc
# ... and the divergence is REAL, not hypothetical: `is_num` — the classifier this file uses for
# `_NCPU`/`MAX_LOAD`/`DISK_MIN_FREE_MB` — rejects that same string. Pinning it here says WHY the
# announcer needs its own reader rather than reusing `is_num`, and fails if someone "tidies" it back.
div="$(bash -c '. "$1"; is_num "0100" && echo agree || echo diverge' _ "$GATE")"
[ "$div" = "diverge" ]; rc=$?
ck "...and \`is_num\` really does NOT agree on it ($div), which is why the two readers cannot be shared" $rc
# ⛔ THE BAND MUST STAY INSIDE THE FILE'S OWN RANGE (review round 2, P2). `is_limit` accepts 9 digits,
# so it accepts floor=999999999 — but the band is 4x the floor, and 4 x 999999999 is 3999999996: TEN
# digits, out of range by the very predicate that guards a PROVIDED warn. Every later guard ACCEPTS
# it (it IS `> floor`), so the "an out-of-range value is repaired" contract above was false, and the
# band sat above every real device — `disk_low` returns true on EVERY spawn, i.e. a PERMANENT warning
# instead of a signal. Assert the INVARIANT, not the one value: whatever the operator sets, the band
# is within the limit AND strictly above the floor. (Pre-fix this prints
# `out-of-range warn=3999999996 (len=10)`; the shape is §4's MAX_LOAD fallback, which already falls
# back to the default on a derivation that produces 10+ digits.)
over="$(DISK_MIN_FREE_MB=999999999 bash -c '
  . "$1"
  len="${#DISK_WARN_FREE_MB}"
  if [ "$len" -le 9 ] && [ "$DISK_WARN_FREE_MB" -gt "$DISK_MIN_FREE_MB" ]; then echo ok;
  else echo "out-of-range warn=$DISK_WARN_FREE_MB (len=$len) floor=$DISK_MIN_FREE_MB"; fi' _ "$GATE")"
[ "$over" = "ok" ]; rc=$?
ck "a floor at the top of is_limit is repaired so the band stays IN RANGE and strictly above it ($over)" $rc
# ⛔ A DISK REFUSAL MUST OUTRANK A LOAD REFUSAL (review round 1, P1). With the load gate first, a
# saturated box with a full filesystem reported ONLY the load refusal — sending the operator to wait
# for load to fall, a remedy that cannot free a filesystem. Both are true at once, so the
# un-clearable one has to be the one reported. Driven: MAX_LOAD=0 AND an unreachable floor.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=0 \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=9999999 bash -c '
    . "$1"
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "both gates refuse" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT")"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a DISK refusal outranks a simultaneous LOAD refusal — the un-clearable one is reported ($res)" $rc
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and the load refusal is NOT the only thing logged in that case" $rc

# POSITIVE CONTROL for the drives below: with a floor this filesystem meets, the agent RUNS.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_disk "$TMP" 1 4)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "POSITIVE CONTROL: above the floor the agent RUNS ($res)" $rc
grep -q PI_RAN "$PI_LOG"; rc=$?
ck "the model was actually invoked when the disk gate allowed it" $rc

# The refusal itself, driven against the real probe with a floor this filesystem cannot meet.
: > "$LOG"; : > "$PI_LOG"
rows_w0=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_w0="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
res="$(drive_disk "$TMP" 9999999)"
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "run_agent below the disk floor returns AGENT_DISK_REFUSED and sets AGENT_STARTED=0 ($res)" $rc
[ ! -s "$PI_LOG" ]; rc=$?
ck "no model was invoked on a disk refusal (proven live by the control above)" $rc
# The refusal must NAME the gate, the MEASURED reading and the floor: an operator reading the log has
# to be able to tell a disk refusal from a load refusal, because the two demand opposite responses.
grep -q 'disk-gate.*REFUSED.*MB free on .*disk_min_free_mb=9999999' "$LOG"; rc=$?
ck "the refusal line names the gate, the measured free space and the floor" $rc
# 77, not 75: a load refusal clears when the box quietens; a disk refusal never clears on its own.
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "a disk refusal is NOT reported as a load refusal (the remedies are opposite)" $rc
# No walltime row on a refusal (no agent ran) — the #1709 series must not gain a fabricated zero.
rows_w1=0; [ -s "$TMP/O/state/walltime.tsv" ] && rows_w1="$(wc -l < "$TMP/O/state/walltime.tsv" | tr -d ' ')"
[ "$rows_w1" = "$rows_w0" ]; rc=$?
ck "a disk refusal appends NO walltime row ($rows_w1 vs $rows_w0 before)" $rc
# ... but it DOES append a disk row: unlike walltime, "the disk was below the floor" IS the
# measurement, and a series that records only refusals cannot answer "how close did we get".
row="$(tail -1 "$TMP/O/state/disk.tsv" 2>/dev/null)"
f4="$(printf '%s' "$row" | cut -f4)"; f5="$(printf '%s' "$row" | cut -f5)"
nf="$(printf '%s' "$row" | awk -F'\t' '{print NF}')"
case "$f4" in ''|*[!0-9]*) rc=1 ;; *) rc=0 ;; esac
[ "$rc" -eq 0 ] && [ "$nf" = "5" ] && [ "$f5" = "$TMP" ]; rc=$?
ck "a refusal records the MEASURED reading + path in disk.tsv (nf=$nf, free='${f4:-<none>}', path='${f5:-<none>}')" $rc

# The WARN band: inside it the agent STILL STARTS — the warning is the point, not a second refusal.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_disk "$TMP" 1 9999999)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "inside the warning band the agent STILL STARTS ($res) — a warning is not a refusal" $rc
grep -q 'disk-gate.*WARN.*warn band 9999999MB' "$LOG"; rc=$?
ck "and it WARNS loudly, naming the reading and the band — a device that fills SILENTLY is the defect" $rc

# The UNREADABLE probe, driven end to end: the floor is unreachable but `df` cannot answer, so the
# gate must fail OPEN (otherwise one bad probe would stop every lane for ever) — and it must SAY SO,
# because silent fail-open is how a typo'd DISK_GATE_PATH disarms the gate invisibly.
: > "$LOG"; : > "$PI_LOG"
res="$(drive_disk "$TMP/no-such-path-$$" 9999999)"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "an UNREADABLE probe fails OPEN — an unanswerable probe is not evidence of a full disk ($res)" $rc
grep -q 'disk-gate.*WARN.*could not read free space' "$LOG"; rc=$?
ck "...and an unreadable probe is ANNOUNCED, so a misconfigured path is not silently permissive" $rc

# ⛔ A NON-EMPTY BUT NON-NUMERIC READING IS "UNREADABLE" TOO, AND MUST BE ANNOUNCED (review round 1,
# P2). `disk_ok`/`disk_low` BOTH classify a non-numeric reading as unreadable and fail open on it, but
# the announcement tested `-z` — so the reading the predicates call "unreadable" was the one reading
# the operator was never told about, and the comment above claimed the opposite. That is the shape the
# OFMT bug in `disk_free_mb` produces (`2.14748e+09`), i.e. the two defects compound: the probe hands
# back a non-number and the WARN that exists for it stays silent. Driven by REPLACING the probe after
# it is sourced — the only non-numeric shape reachable once the conversion is `printf "%d"`.
: > "$LOG"; : > "$PI_LOG"
res="$(PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 DISK_GATE_PATH="$TMP" \
  DISK_MIN_FREE_MB=9999999 bash -c '
    . "$1"
    disk_free_mb() { printf "%s" "9.7e+15"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "non-numeric probe" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT")"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a NON-NUMERIC reading fails OPEN like an empty one — it is not a claim that the disk is full ($res)" $rc
grep -q 'disk-gate.*WARN.*could not read free space' "$LOG"; rc=$?
ck "...and a NON-NUMERIC reading is ANNOUNCED too — the predicates call it unreadable, so the log must agree" $rc

# ── 12) a suite nothing RUNS is not a gate ──────────────────────────────
# ⛔ THIS SUITE IS NOW A REGISTERED CI SHARD (review round 2, P1). It was not, and the block that
# stood here said `scripts/run-bash-shards.sh` was "held by concurrent lanes (PR #1769/#1730), so the
# entry cannot be added from here". #1769 is MERGED (a5fa100, an ancestor of this head) — and, more to
# the point, the equality that sentence justified COULD NEVER FIRE, because nothing ran the suite.
# That is the inert-enforcer shape a prior review on PR #1807 had already falsified: "the assertion
# cannot fire, so the residual can go quiet — indefinitely". The entry is now in the shard list, so a
# regression in ANY check above fails `bash-suites` on every PR; UN-wiring it is a visible diff in the
# shard list, which is where that decision belongs.
# The check below still asserts the SUITE POPULATION, because the failure it guards is SILENCE. Two
# harness suites are deliberately NOT in the shard list — README §suites records both as "Not part of
# the loop" (they drive the claim CAS against a live origin from throwaway clones, i.e. they need a
# network remote): test-claims.sh and test-crossbox.sh. Any OTHER unwired suite turns this red.
# ⛔ MEMBERSHIP IS READ FROM WHAT THE RUNNER EXECUTES, NOT FROM ITS TEXT (review round 3, P2 —
# REPRODUCED). A `grep` of the shard list is satisfied by a COMMENTED-OUT `run_shard` line, which
# executes nothing: with this suite's entry commented out, the previous check stayed GREEN while
# `run-bash-shards.sh --list` printed zero entries for the file. `--list` is the runner's own oracle
# — the same one the lane reads — so membership is asserted against its output.
# ⛔ AND THE POPULATION IS ENUMERATED BY NAME, WITH ITS LIMIT STATED (review round 3, P2). The previous
# globs (`*.test.sh`, then `test-*.sh`) could not see `selftest.sh`, which IS a wired suite — so an
# UN-wired suite named that way would go unreported while this check claimed to speak for the
# population. The population below is the three naming conventions this directory actually uses:
# `*.test.sh`, `test-*.sh` and `selftest.sh`. STATED LIMIT: a suite named NONE of those is outside
# this check's population, exactly as the `pi`-census above states its own limit.
SHARDS="$(cd "$HERE/.." && pwd)/run-bash-shards.sh"
# The runner's own answer. A failed or empty `--list` makes every assertion below fail (fail-closed).
LIST="$(bash "$SHARDS" --list 2>/dev/null)"
# ⛔ HERE-STRINGS, NOT `printf … | grep -q` (#841): with `pipefail` set, `grep -q` exits on its first
# match, the writer takes SIGPIPE, and the PIPELINE's status becomes 141 — so `rc=$?` records a SIGPIPE
# instead of the match. `scripts/check-no-sigpipe-grep.sh` flags the idiom by SHAPE and gates CI on it,
# so the form is what matters here, whatever the payload happens to be today.
grep -qx 'scripts/orchestrator-harness/spawn-gate.test.sh' <<<"$LIST"; rc=$?
ck "this suite IS EXECUTED by run-bash-shards.sh (--list), not merely named in its text" $rc
unwired=""
for f in "$HERE"/*.test.sh "$HERE"/test-*.sh "$HERE"/selftest.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  grep -q "/$b\$" <<<"$LIST" || unwired="$unwired $b"
done
unwired="${unwired# }"
[ "$unwired" = "test-claims.sh test-crossbox.sh" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      unwired suites: [${unwired:-<none>}]"
ck "the orchestrator-harness suites NOT executed by run-bash-shards.sh are exactly the two documented non-loop ones [$unwired]" $rc

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
