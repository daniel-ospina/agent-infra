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
# ⛔ THE FIXTURE IS A REAL BRIEF NOW (agent-infra#2258). `run_agent` refuses a brief that carries no
# research contract (AGENT_BRIEF_REFUSED, 80) BEFORE it reads load or disk, so a fixture of
# `printf 'a prompt\n'` would turn every control below into a brief refusal and the load/disk
# assertions would pass while testing nothing. Rendering the canonical block from the shipped helper
# keeps this suite's fixture HONEST (it is the same text a real dispatch carries) and pins the gate's
# own advice as admissible — if the canonical block ever stopped satisfying the validator, this line
# fails here rather than in production.
PROMPT_SECTION="$(bash "$HERE/brief-gate.sh" --section lane 2>/dev/null)"
[ -n "$PROMPT_SECTION" ] || { echo "  ❌ brief-gate.sh --section produced nothing — cannot build a valid fixture" >&2; exit 1; }
{ printf 'a prompt for a lane\n\n'; printf '%s\n' "$PROMPT_SECTION"; } > "$PROMPT"
bash "$HERE/brief-gate.sh" --check "$PROMPT" lane 2>/dev/null \
  || { echo "  ❌ the suite's own fixture brief is REFUSED by the gate — the fixture is not a brief" >&2; exit 1; }

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
# ⛔ gate-policy.sh IS COPIED DELIBERATELY (agent-infra#2319): fix-one.sh now sources it, and this rig
# exists to prove a MISSING spawn-gate.sh refuses — not to prove a missing policy refuses. Without it
# here the rig would pass for the wrong reason (rc=78 from the policy, with the right-looking message).
cp "$HERE/lane.sh" "$HERE/fix-one.sh" "$HERE/gate-policy.sh" "$NX/"
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
  # A NON-LAUNCHER PATH IS EXCLUDED BY NAME, and the exclusion is ASSERTED rather than trusted.
  # `pi-done-not-exited.py` (#2163) INSPECTS print-mode `pi` processes: it quotes
  # `pi -p --no-session` in its prose and matches the launch shape in a regex (it is how it tells a
  # launcher from a bystander), but it launches nothing. Carrying those tokens is precisely the
  # false-positive class this detector's STATED LIMITS paragraph names, and the exclusion list is
  # where the paragraph says a non-launcher belongs — declaring it in EXPECTED_PI instead would
  # assert the opposite of the truth, that a census of launch paths contains a file with none.
  # The exclusion hides nothing: the assertion below the censuses requires that file to carry no
  # spawn primitive at all, so a future launch path added to it comes back into the census.
  # ⛔ `ai-drainer.sh` IS THE SAME CLASS, AND IT LANDED AFTER THIS CENSUS (#2639/#2799). It launches
  # nothing itself — it DISPATCHES the gated dispatchers (`nonblocking-dispatch.sh`/`bg-dispatch.sh`,
  # which route through `run_agent`) — but its prose quotes `pi -p --no-session` when explaining why
  # `LANE_MEM_MB` is 512, so the token pair matches. That made this shard RED on `main` for every PR
  # that rebased onto it (found while rebasing #2323: `got_pi` carried `ai-drainer.sh`). Excluded by
  # name, with its own non-launcher assertion below — the same ruling, not a second exception class.
  local p found="" FLAG
  FLAG='(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)'
  while IFS= read -r p; do
    case "$p" in
      */retired/*|*/testdata/*|*.test.*|*/selftest.sh|*.md|*.txt|*.json|*.env|*/pi-done-not-exited.py|*/ai-drainer.sh) continue ;; esac
    grep -qE -e "$FLAG" "$ROOT/$p" 2>/dev/null || continue
    grep -qF -e '--no-session' "$ROOT/$p" 2>/dev/null || continue
    found="$found $p"
  done < <(git -C "$ROOT" ls-files --cached --others --exclude-standard "$@")
  # ⛔ SORTED, so the EQUALITY below is a SET equality. `git ls-files --cached --others` emits
  # UNTRACKED files first and then the sorted index, so a brand-new invoker (this suite's own
  # #2163 case: lane-exec.sh before it was committed) made the census disagree with a sorted
  # EXPECTED list for a reason that has nothing to do with the population — a red that says
  # "a launch path is ungated" when the truth is "the file is not staged yet". Sorting both sides
  # keeps the assertion strict about MEMBERSHIP and indifferent to staging state.
  [ -n "$found" ] || { printf ''; return 0; }
  printf '%s\n' ${found# } | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}
# The censuses need a git work tree: `git ls-files` is the index-bounded primitive (per AGENTS.md
# "Search"), and if it fails the set comes back empty and the EQUALITY below goes RED — fail-closed,
# which is the right direction for a guard whose job is "no ungated launch path exists".
ROOT="$(cd "$HERE/../.." && pwd)"
# merge-one.sh is NOT ported here: it is owned by a concurrent lane (PR #1769/#1730). lane-exec.sh is
# the #2163 launcher, which carries no wrapper BY DESIGN (see its own assertion below). The assertion
# is deliberately an EQUALITY, so each residual is asserted rather than left silent, and a NEW
# pi-invoker — or a regression in these — fails it.
EXPECTED_PI="lane-exec.sh merge-one.sh spawn-gate.sh"
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
# `scripts/orchestrator-harness/lane-exec.sh` (#2163) is the launcher that `exec`s pi (declared below).
EXPECTED_PI_TREE="scripts/cloud-cell-bringup.sh scripts/orchestrator-harness/lane-exec.sh scripts/orchestrator-harness/merge-one.sh scripts/orchestrator-harness/spawn-gate.sh scripts/review-pr.sh"
got_tree="$(scan_pi 'scripts/*')"
[ "$got_tree" = "$EXPECTED_PI_TREE" ]; rc=$?
[ "$rc" -eq 0 ] || echo "      tree-wide pi-invokers found: [${got_tree:-<none>}]"
ck "the tree-wide pi-invokers are exactly [${EXPECTED_PI_TREE}] (cloud-cell-bringup.sh + lane-exec.sh declared)" $rc
# ⛔ lane-exec.sh (#2163) is the SPAWN-POINT-GATED launcher: it `exec`s `pi`, so it has no wrapper to
# route through run_agent() and no place to apply the DISK gate (which is per-worktree and therefore
# a caller's business, the same named residual cloud-cell-bringup.sh carries). The LOAD gate reaches
# it anyway, at the shim. What this pins is the half that made it worth writing: it must EXEC, never
# background — a fork here would re-create the surviving wrapper the issue exists to remove.
grep -qE '^[[:space:]]*exec pi ' "$HERE/lane-exec.sh" && rc=0 || rc=1
ck "lane-exec.sh EXECs pi (no wrapper survives the turn)" $rc

# ... and the one path excluded by NAME is really a NON-launcher, because that is the whole reason it
# may sit outside the census. Asserted on the SPAWN PRIMITIVES, deliberately not on `run_agent` —
# this file names `run_agent` and `pi` in prose and matches both in regexes on purpose (telling a
# launcher from a bystander is its job). If it ever gains a way to START a process, this goes RED and
# the path comes out of the exclusion list above.
if grep -qE 'subprocess|Popen|os\.system|os\.exec|os\.spawn|os\.fork|popen' "$HERE/pi-done-not-exited.py" 2>/dev/null; then rc=1; else rc=0; fi
ck "the excluded pi-done-not-exited.py is a NON-launcher (carries no spawn primitive), so its census exclusion hides no launch path" $rc
# …and the same proof for ai-drainer.sh, stated as the detector's own predicate: strip the `#`-comments
# and the token PAIR is gone, so what matched was prose. A real launch added to that file (in code)
# puts the pair back and this arm goes RED — the exclusion cannot swallow one.
_nl_flag='(^|[^[:alnum:]_-])(-p|--print)([^[:alnum:]_-]|$)'
_nl_code="$(sed 's/#.*//' "$HERE/ai-drainer.sh" 2>/dev/null)"
if grep -qE -e "$_nl_flag" <<<"$_nl_code" && grep -qF -- '--no-session' <<<"$_nl_code"; then rc=1; else rc=0; fi
ck "the excluded ai-drainer.sh is a NON-launcher in CODE (it only DISPATCHES gated dispatchers; the pi token pair lives in its prose), so its census exclusion hides no launch path" $rc

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
# ⛔ THE CREATION BACK-PRESSURE GATE IS SUPPLIED A READING, NOT SWITCHED OFF (#2409). `run_agent` now
# measures the repo's landing ratio immediately before any spawn, through `gh` — and these arms drive
# it straight from this checkout (whose origin IS agent-infra), so the system `gh` would answer
# `LAND-BACKLOG` and every positive control below would be refused by the WRONG gate (measured: 14
# arms). Supplying the reading is the fix the #2333 review established for its CI-queue gate: an env
# var that opens a gate is not a gate, so this puts a calm answer where the gate actually reads.
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# ⛔ AND THE REPO MUST BE SUPPLIED TOO (review cycle 2, P2). `land_backlog_repo` derives owner/name
# from the CURRENT worktree's origin, so every driver below that ran in "whatever checkout the runner
# started in" reddened 14 arms the moment that checkout had no GitHub origin (measured: `cd /tmp` ->
# 82 passed / 14 failed, all "rc=74 started=0"). A fixture with a GitHub origin makes the reading
# explicit, exactly as `capacity-transfer.test.sh` §LB does — the arms then test their SUBJECT.
FIXREPO="$TMP/repofix"; mkdir -p "$FIXREPO"
git init -q "$FIXREPO" && git -C "$FIXREPO" remote add origin https://github.com/owner/repo.git

# drive <load> <label> [<max-load>] — runs the SHIPPED run_agent under a controlled reading. `load1`
# is re-declared AFTER sourcing, which is the seam described at the top. `pi` is a stub; every
# assertion is on WHETHER IT RAN and on the ledger, never on a model.
drive() { # drive <load> <label> <max-load>
  local load="$1" label="${2:-test agent}" max="${3:-10}"
  : > "$PI_LOG"
  # DISK_MIN_FREE_MB=1 so these LOAD checks cannot be decided by this host's free space, and the
  # headroom gate (DISK_LANE_TREE_MB/DISK_LANE_RESERVE_MB, #2721) is neutralised for the same reason —
  # the disk
  # gate runs first now (that ordering is itself pinned below), so on a genuinely full CI box the
  # load-refusal assertions would otherwise come back 77 and read as a load-gate regression.
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
    . "$1"
    cd "$7" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    LOAD="$2"; MAX_LOAD="$3"; LOG="$4"; PROMPT="$5"; LABEL="$6"
    load1() { printf "%s" "$LOAD"; }
    run_agent 1 "$LOG" "$PROMPT" "$LABEL" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$load" "$max" "$LOG" "$PROMPT" "$label" "$FIXREPO"
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

# ── 7b) A TURN'S STRAGGLERS DO NOT OUTLIVE run_agent (#2163) ────────────────────
# The group the agent runs in is the whole reason the launch is under job control: a `pi` that
# finished its turn can leave a tool child behind, and a wrapper that only `wait`s for pi then exits
# lets it be reparented to init. Measured on the box that motivated #2163: 76 pi-shaped processes for
# 14 working lanes. The stub forks a long sleeper and exits; after run_agent returns the sleeper must
# be GONE. (A red here means the group reap is inert — e.g. the watchdog was launched outside the
# job-control window, which was a real cycle-1 defect.)
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
# A DIRECT background `sleep` (not a subshell), so `$!` IS the sleeper the test must see gone, and a
# cleanup can end exactly that process.
sleep 300 &
printf '%s\n' "$!" > "$STRAGGLER_PID"
exit 0
PI
chmod +x "$TMP/bin/pi"
: > "$TMP/straggler.pid"
PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" STRAGGLER_PID="$TMP/straggler.pid" O="$TMP/O" DISK_MIN_FREE_MB=1 bash -c '
  . "$1"
  LOG="$2"; PROMPT="$3"
  load1() { printf "1"; }
  run_agent 30 "$LOG" "$PROMPT" "straggler test" >/dev/null 2>&1
' _ "$GATE" "$LOG" "$PROMPT" 2>/dev/null
sp="$(cat "$TMP/straggler.pid" 2>/dev/null)"
# ⛔ AN EMPTY PID FILE IS A FAILED LEG, NOT A PASS (#2163 review, P3). The stub writes the sleeper's
# pid; if it is absent the agent never ran, and `[ -n "$sp" ] && …` would then fall through to success
# — making the ONLY behavioural proof of the group reap vacuously green on an inert launch.
survivor=0
case "$sp" in
  ''|*[!0-9]*) rc=1 ;;
  *) if kill -0 "$sp" 2>/dev/null; then rc=1; survivor=1; else rc=0; fi ;;
esac
if [ "$survivor" = "1" ]; then
  # Cleanup, fenced on WHAT the pid is: a recycled pid must not be killed blindly.
  case "$(ps -o args= -p "$sp" 2>/dev/null)" in
    *"sleep 300"*) kill -KILL "$sp" 2>/dev/null ;;
  esac
fi
ck "run_agent reaps the turn's straggler (pid ${sp:-<none>} is gone after the turn)" $rc
# restore the plain stub for the cases below
cat > "$TMP/bin/pi" <<'PI'
#!/bin/sh
echo "PI_RAN" >> "$PI_LOG"
exit 0
PI
chmod +x "$TMP/bin/pi"

# ── 8) the gate RE-READS at the spawn, and a refusal is not a `pi` exit status ───
# This is the whole point of the port: a chain-<N> worker dispatched on a quiet box may open its PR
# 90 minutes later, and the reading that governs is the one taken at the spawn.
got="$(PATH="$TMP/bin:$PATH" O="$TMP/O" bash -c '
  . "$1"
  cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
  MAX_LOAD=10
  load1() { printf "2"; }                   # the controller-time reading: quiet
  can_spawn "$(load1)" || exit 9            # would have allowed the session
  load1() { printf "99"; }                  # load has since spiked
  run_agent 5 "$2" "$3" "late chain worker" >/dev/null 2>&1
  printf "rc=%s" "$?"
' _ "$GATE" "$TMP/log2" "$PROMPT" "$FIXREPO" 2>/dev/null)"
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
  cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
  load1() { printf "0"; }
  MAX_LOAD=10
  run_agent 1 "$2" "$3" "pi that exits 75 itself" >/dev/null 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$GATE" "$TMP/log3" "$PROMPT" "$FIXREPO" 2>/dev/null)"
[ "$got" = "rc=75 started=1" ]; rc=$?
ck "a pi that itself exits 75 is reported STARTED, not as a load refusal (want rc=75 started=1, got '${got:-<none>}')" $rc

# ⛔ …AND THE SAME FOR 74 AND 73 (review P2, agent-infra#2293; renumbered by the #2293x#2409 batch).
# PI_FORK_REFUSED used to BE 74 — the identical value as AGENT_FORK_REFUSED then — so run_agent's arm could
# not tell the shim's refusal from a real `pi` that exited 74 (EX_IOERR): a model run that hit a disk
# I/O error was reported as "this box could not fork" AND had AGENT_STARTED cleared, which is the
# #1720 class in the other direction. The spawn-point code is now 78 and the caller-facing one stays
# 73, mirroring the load pair (76 at the spawn point, 75 for the caller). ⛔ 73 and NOT 74: 74 is
# AGENT_LAND_BACKLOG, whose remedy is the opposite of a fork refusal's, so "stays 74" here was
# stale pre-renumber prose that stated the very collision the renumber removes.
# pre-change tree: it produced rc=74 started=0.
mkdir -p "$TMP/bin74"
printf '#!/bin/sh\nexit 74\n' > "$TMP/bin74/pi"
chmod +x "$TMP/bin74/pi"
# Resolved HERE rather than reused from the later section: the suite runs under `set -u`, so a variable
# assigned further down is UNBOUND at this point — which made this arm report '<none>' instead of
# failing for the reason it names.
_capmod74="$HERE/capacity.sh"
[ -f "$_capmod74" ] || _capmod74="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)/orchestrator-harness/capacity.sh"
got="$(PATH="$TMP/bin74:$TMP/bin:$PATH" O="$TMP/O" DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 bash -c '
  . "$1" 2>/dev/null
  cap_procs_live() { printf "400"; }
  cap_ulimit_u() { printf "15641"; }
  cap_maxprocperuid() { return 1; }
  . "$2"
  load1() { printf "0"; }
  MAX_LOAD=10
  run_agent 1 "$3" "$4" "pi that exits 74 itself" >/dev/null 2>&1
  printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
' _ "$_capmod74" "$GATE" "$TMP/log4" "$PROMPT" 2>/dev/null)"
[ "$got" = "rc=74 started=1" ]; rc=$?
ck "a pi that itself exits 74 (EX_IOERR) is STARTED, not read as the fork gate's refusal (want rc=74 started=1, got '${got:-<none>}')" $rc
# …and the two codes are DISTINCT in the shipped source, which is the property that makes the arm
# above possible at all. A grep of the declaration, so a future re-merge of the two is caught even if
# the behavioural arm is ever weakened.
_pf="$(grep -m1 '^PI_FORK_REFUSED=' "$GATE" | cut -d= -f2)"; _af="$(grep -m1 '^AGENT_FORK_REFUSED=' "$GATE" | cut -d= -f2)"
{ [ -n "${_pf:-}" ] && [ -n "${_af:-}" ] && [ "$_pf" != "$_af" ]; }; rc=$?
ck "the spawn point's fork code ($_pf) is DISTINCT from the caller-facing one ($_af) — a pi exiting the latter cannot be mistaken for the gate" $rc

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
# ⛔ THE FIXTURE IS A CHECKOUT OF THE REPO THE ARMS NAME (agent-infra#2724/#2694). lane.sh/fix-one.sh
# now assert the worktree's origin against the target slug and refuse (72) when it differs or is
# unreadable — so a fixture with no origin would be refused by the REPO gate and every load/disk arm
# below would assert a gate that never ran.
git -C "$RREPO" remote add origin https://github.com/daniel-ospina/agent-infra.git
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
# ── THE CI-QUEUE READING THIS RIG MUST SUPPLY (agent-infra#2296) ────────────────────────────────
# `ci-queue.sh` now gates EVERY fixer lane on a MEASURED queue read, and an UNREADABLE queue defers
# (fail-closed — an unreadable queue is not an empty one). The `gh` stub above FAILS every call by
# design (the arms below need a failing `gh pr view`), so without a genuine reading every fixer arm
# would be deferred before it ever reached the load/disk gate it exists to test: six "load-gate
# regressions" that are not regressions. That is what these seven arms reported before this stub
# existed, on a tree where nothing was wrong with the load gate.
# ⛔ THE READING IS SUPPLIED, NOT THE GATE SWITCHED OFF. `gh-queue` answers ONLY the three endpoints
# `ci-queue.sh` reads, with a SHALLOW queue (1 queued, 0 running, 3 runners → ceiling 6) — the
# production precondition under which a fixer may run — and `ciq_gh`'s documented `CIQ_GH` seam is
# how the module's own suite feeds it too. Nothing here touches `gh`, so the arms that need a failing
# `gh` keep it, and no env var can disable the gate (a gate an env var can open is not a gate).
cat > "$RIG/bin/gh-queue" <<'GHQ'
#!/bin/sh
case "$2" in
  *status=queued*)      echo '{"total_count":1}' ;;
  *status=in_progress*) echo '{"total_count":0}' ;;
  *actions/runners*)    printf '%s\n' '{"total_count":3,"runners":[{"id":1,"name":"r1","status":"online","busy":false},{"id":2,"name":"r2","status":"online","busy":false},{"id":3,"name":"r3","status":"online","busy":false}]}' ;;
  *) exit 1 ;;
esac
GHQ
chmod +x "$RIG/bin/gh-queue"
export CIQ_GH="$RIG/bin/gh-queue"
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
# ⛔ AND WHETHER THE PR-OWNER LOCK WAS HELD WHILE IT RAN (review of PR #2576, P2). §9b's other
# assertions are satisfied by a tree that takes the lock, RELEASES it immediately, and then runs
# the agent that pushes — which is the whole defect. The lock must be held ACROSS the run, so the
# only place that can witness it is the agent stub itself. It records the RECORD'S CONTENT too, so a
# takeover can be told apart from a steal that kept the dead pid in place.
pi() { echo PI_RAN >> "$PI_LOG"; [ -n "${PRLOCK_PATH:-}" ] && [ -f "$PRLOCK_PATH" ] && { echo PI_SAW_LOCK >> "$PI_LOG"; echo "PI_LOCK_OWNER=$(cat "$PRLOCK_PATH" 2>/dev/null)" >> "$PI_LOG"; }; return 0; }
export -f pi
# ...and pin the MECHANISM, not only its effect: the whole fix rests on the function surviving into
# the callers' environment, so assert it is there BY NAME. Otherwise a future edit that drops the
# `export -f` resurfaces as a confusing positive-control red instead of naming its own cause.
env | grep -q '^BASH_FUNC_pi' ; rc=$?
ck "the rig's pi stub is EXPORTED into the callers' environment (a function beats the callers' PATH prepend)" $rc
# `gh` is stubbed to FAIL: an empty `gh pr view` head SKIPS fix-one.sh's cross-box claim block, so
# these checks exercise the gate and the refund, not the claim machinery (which has its own suite).
fix_argv() { printf '%s\n%s\n%s\nwork\n' "$RREPO" "daniel-ospina/agent-infra" 7 > "$RIG/argv7"; }

# ⛔ EVERY LOAD/SUCCESS ARM BELOW PINS DISK_MIN_FREE_MB=1 AND NEUTRALISES THE HEADROOM GATE, AND IT IS NOT COSMETIC (review round 2, P1).
# The disk gate runs FIRST, so without this the arms are decided by THIS HOST's free space: on a box
# with less than the shipped 500 MiB floor — the exact state this PR exists for — each of them gets
# AGENT_DISK_REFUSED=77 instead of the 75/0 it asserts, and six "load-gate regressions" are reported
# that are not regressions. `drive()` above neutralises the disk gate for the same reason and says so;
# the arms that drive the real CALLERS must do it too. Only the arm that INTENDS a disk refusal varies
# the floor (it sets DISK_MIN_FREE_MB=9999999).
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
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
cp "$HERE/fix-one.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" "$HERE/gate-policy.sh" "$RIG/stale/"
# ⛔ THE VALIDATOR TRAVELS WITH THE STALE HELPER, AND THAT IS NOT A WEAKENING (#2258). What is stale
# here is `spawn-gate.sh`'s refusal CONSTANTS, not the brief rules: a fixture that omitted
# `brief-gate.sh` would make fix-one.sh exit 78 (cannot verify) and this arm would read "78" as the
# stale-helper behaviour it is meant to test — passing for the wrong reason. The fixer's dependency on
# the validator is the same class as its dependency on spawn-gate.sh.
cp "$HERE/fix-one.sh" "$RIG/stale/"
cp "$HERE/brief-gate.sh" "$RIG/stale/"
sed -e 's/^AGENT_DISK_REFUSED=77$/# STALE PRE-#1765 HELPER: this constant does not exist/' \
    -e 's/return "\$AGENT_DISK_REFUSED"/return 77/' \
    "$HERE/spawn-gate.sh" > "$RIG/stale/spawn-gate.sh"
# The transformation is ASSERTED, not assumed: if the helper stops matching those patterns the sed
# yields an UNCHANGED file and the arm below would pass for the wrong reason.
grep -q 'AGENT_DISK_REFUSED=' "$RIG/stale/spawn-gate.sh"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and the stale-helper fixture really carries no AGENT_DISK_REFUSED (the sed transformed it)" $rc
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
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
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
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
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
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

# ── 9b) THE PR-OWNER LOCK: a fixer never runs while a LANDER owns the PR ──────
# ⛔ THE SUBJECT IS THE SHIPPED `fix-one.sh`, DRIVEN. The defect is that `merge-one.sh` and the
# doctor's `merge` role serialise on `$O/state/mergeclaim-<PR>.lock` while the ONE worker whose
# product is a PUSH did not, so a lander could re-resolve a head that a fixer then moved under it —
# and the rail refuses, with the attestation the review chain had just minted gone stale. A grep for
# the filename would pass on an arm that opens the lock and never tests it, so every check below runs
# the real script and asserts on what it DID: whether the stub agent ran, whether the chain was
# re-run, which marker was written, and whether a LIVE owner's lock survived.
#
# ⛔ THE HEAD IS STUBBED AS A FUNCTION, NOT AS A FILE, for the reason the `pi` stub above documents:
# fix-one.sh prepends /opt/homebrew/bin and /usr/local/bin to PATH, so a file stub is SHADOWED by a
# system `gh` on any box that has one — and then these arms depend on the host. A function is
# resolved before any PATH lookup, so it cannot be. It answers ONLY the head read and fails
# everything else, which keeps the cross-box claim block and the check read on their documented
# degraded paths (the head is what the bail marker needs).
gh() { # exported: fix-one.sh's PATH prepend would shadow a file stub
  case "$*" in
    *"pr view"*) case "$*" in *"--json headRefOid"*) printf '%s\n' 0123456789abcdef0123456789abcdef01234567; return 0 ;; esac ;; esac
  return 1
}
export -f gh
# The chain stub records the HANDOFF's lock state: "the fixer released the PR-owner lock before
# re-running the chain" is otherwise unobservable (a stub that ignores the lock passes either way).
# MERGE_RC stays honoured — section 10 drives the wrappers through this same stub.
printf '#!/bin/sh\necho MERGE_ONE_RAN >> "$MERGE_LOG"\n[ -n "${PRLOCK_PATH:-}" ] && [ -f "$PRLOCK_PATH" ] && echo MERGE_ONE_SAW_LOCK >> "$MERGE_LOG"\nexit "${MERGE_RC:-0}"\n' > "$RO/merge-one.sh"
chmod +x "$RO/merge-one.sh"
PRLOCK7="$RO/state/mergeclaim-7.lock"

# A LIVE lander: the fixer must defer, refundably, and MUST NOT touch the lander's lock.
sleep 300 & LANDER_PID=$!
printf '%s\n' "$LANDER_PID" > "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc=$?
[ "$plrc" -eq 0 ]; rc=$?
ck "a fixer DEFERS (rc=0) when the LANDER holds the PR-owner lock (rc=$plrc) — contention is not a failure" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "a lander-owned PR starts no agent and does NOT re-run the merge chain" $rc
grep -q 'LANDER owns this PR (state/mergeclaim-7.lock held by live pid' "$RO/logs/fix-7.log"; rc=$?
ck "...and NAMES the lander and its pid, not a generic refusal" $rc
[ -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; rc=$?
ck "...and writes the refundable bail marker for the head it saw (no attempt consumed)" $rc
[ "$(cat "$RO/state/fixcount-7" 2>/dev/null)" = "2" ]; rc=$?
ck "...and leaves fixcount alone — the controller refunds, the fixer does not decrement it" $rc
{ [ -f "$PRLOCK7" ] && [ "$(cat "$PRLOCK7" 2>/dev/null)" = "$LANDER_PID" ]; }; rc=$?
ck "...and the LIVE lander's lock SURVIVES — a deferred fixer must never clear another worker's claim" $rc
kill "$LANDER_PID" 2>/dev/null; wait "$LANDER_PID" 2>/dev/null

# A STALE claim — its owner is MEASURABLY gone — is TAKEN OVER, not refused (#2574 (b)). `merge-one.sh`
# itself reclaims this same file with `rm` + a retry, and `claim_live()` reclaims a dead owner's claim at
# the controller's next dispatch; a fixer that only deferred would leave a manual `adopt-fix` blocked
# behind bookkeeping that recorded a past state and is never revalidated. The takeover must still not be
# the naive `rm && write` (two syscalls, so a peer's LIVE lock can be deleted between them): it renames
# the record aside, VERIFIES what it detached is the dead pid it measured, and only then claims the
# vacated path — so the assertions below check the outcome AND the evidence line.
sleep 0.05 & STALE_PID=$!; wait "$STALE_PID" 2>/dev/null
printf '%s\n' "$STALE_PID" > "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc2=$?
{ [ "$plrc2" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q PI_SAW_LOCK "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG" && grep -q 'RECLAIMED a STALE claim' "$RO/logs/fix-7.log"; }; rc=$?
ck "a STALE claim is TAKEN OVER, not refused: the fixer runs holding it and the chain re-runs (rc=$plrc2)" $rc
grep -qF "RECLAIMED a STALE claim — state/mergeclaim-7.lock named pid $STALE_PID, which is not alive (measured with kill -0)" "$RO/logs/fix-7.log"; rc=$?
ck "...and the takeover NAMES what it reclaimed — the lock and the pid it measured dead" $rc
grep -qx "PI_LOCK_OWNER=$STALE_PID" "$PI_LOG" && rc=1 || rc=0
ck "...and the record the agent worked under is NOT the dead pid (a steal that kept the stale record would pass the line above)" $rc
{ ! grep -q 'DEFERRED' "$RO/logs/fix-7.log" && [ ! -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; }; rc=$?
ck "...and it is NOT a deferral — no bail marker, so no attempt is refunded for work that actually ran" $rc
{ [ ! -f "$PRLOCK7" ] && [ -z "$(ls "$PRLOCK7".reclaim.* 2>/dev/null)" ]; }; rc=$?
ck "...and neither the claim nor the detached stale record is left behind" $rc

# ⛔ THE SAFETY ARM OF THE TAKEOVER, DRIVEN IN ISOLATION — this is the race the review reproduced.
# Between the stale read and the detach a PEER may have reclaimed the lock, and a `rm && write`
# reclaim then deletes that peer's LIVE claim and holds a lock two workers each believe they own.
# `fix-one.sh` detaches by `mv`, CHECKS what it detached against the pid it measured, and puts a peer's
# claim back with `ln` (create-if-absent) before deferring. The functions are EXTRACTED from the
# shipped file — never re-implemented here, or the check would pass on a tree that does the wrong thing.
# ⛔ AND THE PEER'S CLAIM MUST APPEAR *AFTER* THE READ, or the arm is VACUOUS (review of PR #2576, P2):
# writing the live pid before the call makes the function's OWN first re-read fail, so `mv`, the
# verification and the `ln` restore never execute — the check then passes on the banned `rm && write`
# too. So the read is intercepted ONCE (the record answering the pid we measured) and the real file
# already holds the peer's claim: the detach moves the PEER's record, which is exactly the case.
PLG="$TMP/pl"; mkdir -p "$PLG"
awk '/^prlock_take\(\)/{f=1} /^release_prlock\(\)/{f=0} f' "$HERE/fix-one.sh" > "$PLG/lib.sh"
[ -s "$PLG/lib.sh" ] && bash -n "$PLG/lib.sh"; rc=$?
ck "the takeover functions are EXTRACTABLE from the shipped fix-one.sh (the isolated arm below is not vacuous)" $rc
cat > "$PLG/drive.sh" <<'PLGDRIVE'
set -u
PRLOCK="$1/lock"; L="$1/log"; PR=7; O="$1"
. "$1/lib.sh"
live="$2"; stale="$3"
rm -f "$PRLOCK.seen"
printf '%s\n' "$live" > "$PRLOCK"     # the record a PEER holds: it reclaimed after our measurement
cat() { # the FIRST read of the record answers the pid we MEASURED; every later read is the real file
  if [ "$1" = "$PRLOCK" ] && [ ! -e "$PRLOCK.seen" ]; then : > "$PRLOCK.seen"; printf '%s\n' "$stale"; return 0; fi
  command cat "$@"
}
prlock_takeover "$stale"; rc=$?
printf 'rc=%s got=%s leftovers=%s\n' "$rc" "$(command cat "$PRLOCK" 2>/dev/null)" "$(ls "$PRLOCK".reclaim.* 2>/dev/null | wc -l | tr -d ' ')"
PLGDRIVE
bash "$PLG/drive.sh" "$PLG" "$$" "$STALE_PID" > "$PLG/out" 2>&1
{ grep -qx "rc=1 got=$$ leftovers=0" "$PLG/out"; }; rc=$?
ck "a takeover that detaches a PEER's live claim puts it BACK and defers — nothing deleted, nothing left behind ($(cat "$PLG/out" 2>/dev/null))" $rc
# ... and the SAME interception with a record that cannot be restored proves the outcome is REPORTED as
# the different thing it is: a third party re-claims the path while our `ln` restore is being attempted.
cat > "$PLG/drive2.sh" <<'PLGDRIVE2'
set -u
PRLOCK="$1/lock"; L="$1/log"; PR=7; O="$1"
. "$1/lib.sh"
live="$2"; stale="$3"; third="$4"
rm -f "$PRLOCK.seen"
printf '%s\n' "$live" > "$PRLOCK"
cat() {
  if [ "$1" = "$PRLOCK" ] && [ ! -e "$PRLOCK.seen" ]; then : > "$PRLOCK.seen"; printf '%s\n' "$stale"; return 0; fi
  command cat "$@"
}
ln() { if [ "$1" = "$PRLOCK.reclaim.$$" ]; then printf '%s\n' "$third" > "$PRLOCK"; return 1; fi; command ln "$@"; }
prlock_takeover "$stale"; rc=$?
printf 'rc=%s\n' "$rc"
PLGDRIVE2
bash "$PLG/drive2.sh" "$PLG" "$$" "$STALE_PID" "1" > "$PLG/out2" 2>&1
{ grep -qx 'rc=2' "$PLG/out2" && grep -q 'could NOT be restored' "$PLG/log.log"; }; rc=$?
ck "an unrestorable displacement is reported as its OWN outcome (rc=2 + a WARNING), not as 'nothing was deleted' ($(cat "$PLG/out2" 2>/dev/null))" $rc

# ⛔ AN UNREADABLE RECORD IS NOT A STALE ONE, AND STEALING IT IS THE ONE WAY TO TAKE A LIVE LANDER'S
# CLAIM. `merge-one.sh` claims with `( set -o noclobber; echo $$ > "$CLAIM" )`: the file exists for an
# instant BEFORE the pid is written, so "empty ⇒ dead owner" would take a lock whose owner is alive and
# mid-claim. The fixer must treat it as LIVE: defer, and leave it exactly as it found it.
: > "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc2b=$?
{ [ "$plrc2b" -eq 0 ] && [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "an EMPTY claim record is treated as LIVE and DEFERS (rc=$plrc2b, no agent) — a lander mid-claim is not a dead one" $rc
{ [ -f "$PRLOCK7" ] && [ ! -s "$PRLOCK7" ]; }; rc=$?
ck "...and it is left EXACTLY as found — never stolen from a claim whose pid may not be written yet" $rc
grep -q 'no pid this lane can prove dead' "$RO/logs/fix-7.log"; rc=$?
ck "...and says WHICH fact was missing, instead of reporting a stale owner it never measured" $rc
rm -f "$PRLOCK7"

# ⛔ AND A LOCK STATE NO RE-DISPATCH CAN CLEAR IS NOT REFUNDED (review of PR #2576, cycle 2 — P2). A
# `mergeclaim-<PR>.lock` that is a DIRECTORY can never be read as an owner and never be taken; if the
# refusal were refundable, spawn -> defer -> refund would spin for ever with `fixcount` netting to
# zero, so `MAX_FIX_TRIES` would never park the PR and nothing would surface.
rm -f "$PRLOCK7"; mkdir -p "$PRLOCK7"
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc4=$?
{ [ "$plrc4" -eq 0 ] && [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "an UNUSABLE lock path (a directory) refuses before any agent runs (rc=$plrc4)" $rc
grep -q 'REFUSED (NOT refundable' "$RO/logs/fix-7.log"; rc=$?
ck "...and says it is NOT refundable, so the cap can park the PR" $rc
[ ! -f "$RO/state/fixbail-7-0123456789abcdef0123456789abcdef01234567" ]; rc=$?
ck "...and writes NO bail marker — a refundable spin would net fixcount to zero for ever" $rc
grep -q 'REPAIR: inspect it' "$RO/logs/fix-7.log"; rc=$?
ck "...and NAMES the repair for the unusable path" $rc
rmdir "$PRLOCK7" 2>/dev/null || rm -rf "$PRLOCK7"

# ⛔ THE OTHER NON-REFUNDABLE ARM — a `$O/state` that cannot be WRITTEN — had no test (review of PR
# #2576, P3). There the lock path does not exist, so the fixer reaches the create-failure refusal, and
# if a regression made that arm refundable, spawn -> defer -> refund would spin with `fixcount`
# netting to zero for ever. Driven with a separate `$O` whose `state` is a REGULAR FILE, which needs no
# root: every `state/...` write then fails with ENOTDIR, exactly the unwritable/corrupt shape this arm
# exists for.
RO3="$RIG/O3"; rm -rf "$RO3"; mkdir -p "$RO3/logs"; : > "$RO3/state"
: > "$PI_LOG"; : > "$MERGE_LOG"
( cd "$RREPO" && O="$RO3" CIQ_STATE_DIR="$RO/state" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$RO3/state/mergeclaim-7.lock" bash "$HERE/fix-one.sh" "$RREPO" "daniel-ospina/agent-infra" 7 work ) >/dev/null 2>&1; plrc5=$?
{ [ "$plrc5" -eq 0 ] && [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "an UNWRITABLE state dir refuses before any agent runs (rc=$plrc5) — the second non-refundable arm" $rc
grep -q 'REFUSED (NOT refundable' "$RO3/logs/fix-7.log"; rc=$?
ck "...and says it is NOT refundable — otherwise spawn -> defer -> refund spins with fixcount netting to zero" $rc
grep -q 'could not be CREATED although no file exists there' "$RO3/logs/fix-7.log"; rc=$?
ck "...and names the CAUSE it measured (the create failed on an absent path), not a stale owner it never saw" $rc

# POSITIVE CONTROL, and the assertion that pins the property the change exists for: with NO lock the
# fixer runs, the lock is HELD WHILE THE AGENT RUNS, and it is RELEASED before the merge-one handoff
# (otherwise merge-one.sh takes the same lock first and exits "already owns this PR", skipping the
# fixer's own re-review — #2132's strand).
fix_argv; printf '2\n' > "$RO/state/fixcount-7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1; plrc3=$?
{ [ "$plrc3" -eq 0 ] && grep -q PI_RAN "$PI_LOG" && grep -q MERGE_ONE_RAN "$MERGE_LOG"; }; rc=$?
ck "POSITIVE CONTROL: with no lander the fixer RUNS and the chain is re-run (rc=$plrc3)" $rc
grep -q PI_SAW_LOCK "$PI_LOG"; rc=$?
ck "...and the lock is HELD WHILE THE AGENT RUNS — the property, not just the acquisition line" $rc
{ grep -q MERGE_ONE_RAN "$MERGE_LOG" && ! grep -q MERGE_ONE_SAW_LOCK "$MERGE_LOG"; }; rc=$?
ck "...and it is RELEASED before handing the PR to merge-one.sh (else the chain refuses its own re-review)" $rc
[ ! -f "$PRLOCK7" ]; rc=$?
ck "...so no lock is left behind by a completed fixer run (a stale lock would defer the next cycle)" $rc

# ⛔ (c) THE CLAIM IS RELEASED ON THE CRASH PATH TOO — a lock leaked by a KILLED fixer is the same
# stall one step later, and it is the path an operator never sees (nothing in the log after the
# signal). The fixer is backgrounded, the `pi` stub BLOCKS so the worker is provably mid-run when it
# is signalled, and the assertion is on the record: it named a live process before, and it is gone
# after. A tree that releases only on its success path passes the positive control above and fails here.
rm -f "$PRLOCK7"; : > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/fix-7.log"
# ⛔ THE BLOCKING STUB POLLS A STOP FILE INSTEAD OF `sleep 20` (review of PR #2576, P3). A bare
# `sleep` is a CHILD of the fixer: `kill -TERM` reaches the shell, whose EXIT trap releases the claim
# and exits, so the sleep survives — reparented and outliving the suite for its full duration (measured:
# `pgrep -af '^sleep 20$'` after the run). Polling with a 0.1 s tick and a STOP file lets this arm stop
# it deterministically without weakening what it proves (the fixer is mid-agent when it is signalled).
PI_STOP="$TMP/pi.stop"; rm -f "$PI_STOP"
pi() { echo PI_RAN >> "$PI_LOG"; [ -n "${PRLOCK_PATH:-}" ] && [ -f "$PRLOCK_PATH" ] && echo PI_SAW_LOCK >> "$PI_LOG"; i=0; while [ "$i" -lt 600 ]; do [ -f "${PI_STOP:-/nonexistent}" ] && return 0; sleep 0.1; i=$((i+1)); done; return 0; }
export -f pi
fix_argv; printf '2\n' > "$RO/state/fixcount-7"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=60 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    PI_STOP="$PI_STOP" PRLOCK_PATH="$PRLOCK7" bash "$HERE/fix-one.sh" --argv "$RIG/argv7" ) >/dev/null 2>&1 & fixpid=$!
i=0; while ! grep -q PI_RAN "$PI_LOG" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done
held="$(cat "$PRLOCK7" 2>/dev/null)"
{ [ -n "$held" ] && kill -0 "$held" 2>/dev/null; }; rc=$?
ck "while the agent works the claim names the LIVE fixer (lock=${held:-<none>}) — the crash arm is not vacuous" $rc
# ⛔ SIGNAL THE LOCK OWNER, NOT THE SUBSHELL WRAPPER. `$fixpid` is the `( … ) &` subshell, NOT
# `fix-one.sh` — measured on this box: wrapper=11948, lock owner=11953. Killing the wrapper makes
# `wait` return 143 the instant the WRAPPER dies, while the fixer is still inside its `pi` stub, so
# its claim is legitimately still present at assert time: the arm failed on TIMING, not on a leak
# (the lock did disappear ~0.5 s later, unchanged). It also proved less than it claims — the signal
# never reached the process whose EXIT trap is under test. `$held` IS that process (the pid
# `prlock_take` wrote), so signal it, and the wrapper's `wait` then observes the fixer's own death.
kill -TERM "${held:-$fixpid}" 2>/dev/null; : > "$PI_STOP"; wait "$fixpid" 2>/dev/null; crc=$?
[ ! -f "$PRLOCK7" ]; rc=$?
ck "a SIGTERM'd fixer RELEASES the claim (exit $crc, lock=${PRLOCK7##*/}) — a lock leaked by a dead fixer stalls the PR one step later" $rc
[ ! -s "$MERGE_LOG" ]; rc=$?
ck "...and the killed run did NOT hand the PR to the chain (a half-finished fixer must not trigger a re-review)" $rc
# the blocking stub must not outlive the arm: its poll observes the stop file on the next 0.1s tick
sleep 0.4
{ ! grep -q 'while \[ "\$i" -lt 600 \]' "$HERE/spawn-gate.test.sh" || grep -q 'PI_STOP' "$HERE/spawn-gate.test.sh"; }; rc=$?
ck "...and the blocking stub waits on a STOP FILE, not a bare \`sleep\` that outlives the killed worker" $rc
# restore the fast stub for the section that follows, and reap the blocked one
pi() { echo PI_RAN >> "$PI_LOG"; return 0; }
export -f pi
# ⛔ AND THE CROSS-BOX REFUSAL — the FIFTH rc=0-with-nothing-pushed arm (review of PR #2576, P3).
# `fix-one.sh` refuses when another box already holds the per-head claim, and its line carries no
# `DEFERRED` token, so without its own arm the operator's log got no line and the status said
# SUCCESS for a run that did nothing. Driven with a claims.sh stub that refuses, and removed again so
# the arms below are not diverted onto this path.
# the deployed copies §10 uses; made here because this arm runs before §10's cp
# ⛔ AND THE IDENTITY MODULE GOES WITH THEM (#2762/#2694): adopt-fix.sh and fix-one.sh source
# `$SELF/repo-target.sh` (and it sources repo-slug.sh), so a copy without them exits 78 — a
# half-deployed box — instead of reaching the claim refusal this arm is about.
# ⛔ AND EVERY MODULE THE FIXER HARD-REQUIRES, NOT JUST THE TWO THE ARM IS ABOUT (review, P1).
# `fix-one.sh` `exit 78`s without each of spawn-gate.sh (L54), brief-gate.sh (L62, resolved from
# `$SELF` here, because spawn-gate.sh's `brief_gate_lib` prefers the script's OWN directory),
# repo-target.sh (L69) and gate-policy.sh (L73). This rig seeded only four of the five, so the arm
# returned 78 — a HALF-DEPLOYED BOX — and its assertions read as "the cross-box refusal is broken"
# when the refusal was never reached (measured: `got 78`, on this tree and in CI). The two modules
# this comment once left to luck are copied explicitly; the fallbacks `brief_gate_lib` also consults
# (`$AGENT_INFRA_PATH`, `~/.pi/agent/scripts`) are NOT relied on, so the arm cannot pass on a dev box
# and fail on a runner whose HOME has no harness scripts (same class as round 3's HOME fix).
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/brief-gate.sh" "$HERE/gate-policy.sh" \
   "$HERE/adopt-fix.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" "$RO/"
# …and the arm must not be satisfiable by a rig that never reached the claim block: assert the
# modules it needs are actually in $RO, so a future edit that drops one fails HERE, naming the
# missing file, instead of resurfacing as a bogus 78 two assertions later.
_rigmiss=""
for _m in fix-one.sh spawn-gate.sh brief-gate.sh gate-policy.sh repo-target.sh repo-slug.sh; do
  [ -f "$RO/$_m" ] || { echo "❌ the §9 rig is missing $_m in \$RO — the cross-box arm below would exit 78 before its refusal"; _rigmiss="$_m"; }
done
[ -z "$_rigmiss" ]; rc=$?
ck "the §9 rig carries every module fix-one.sh hard-requires (a rig missing one asserts a HALF-DEPLOYED refusal, not the claim refusal)" $rc
printf '#!/bin/sh\nclaim_acquire() { CLAIM_RESULT="another box owns this head (test stub)"; return 1; }\n' > "$RO/claims.sh"
: > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; rm -f "$RO/state/fixbail-7-"*
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arccb=$?
[ "$arccb" -eq 79 ]; rc=$?
ck "adopt-fix.sh reports a CROSS-BOX claim refusal as 79 (got $arccb) — not SUCCESS for a run that pushed nothing" $rc
grep -q 'CROSS-BOX claim' "$RO/logs/adopt-7.log"; rc=$?
ck "...and NAMES it in the log the operator reads" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "...and nothing ran: no agent, no merge chain" $rc
rm -f "$RO/claims.sh" "$RO/state/fixbail-7-"*
unset -f gh; unset 'BASH_FUNC_gh%%'

# ── 10) the WRAPPERS propagate the status ───────────────────────────────────────
# adopt-fix.sh and chain-merge.sh are report-then-`echo` scripts: their LAST command used to be a
# reporting `echo`, so `$?` was echo's — always 0 — and a wrapper doing `… && next` took the SUCCESS
# branch whatever happened. Drive each and read the EXIT CODE.
# ⛔ AND DRIVE MORE THAN ONE CODE (P2, review round 2026-10-15, second pass). A 75-only assertion is
# satisfied by a wrapper that HARDCODES 75 — which would report a crash as a load refusal and make the
# controller re-dispatch for ever. The property under test is PROPAGATION, so 0 and 1 are driven too.
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/repo-target.sh" "$HERE/repo-slug.sh" "$HERE/chain-merge.sh" "$HERE/adopt-fix.sh" "$HERE/gate-policy.sh" "$RO/"
# …and the brief validator, because fix-one.sh now HARD-REQUIRES it (#2258): `brief_gate_lib` prefers
# `$O/brief-gate.sh`, so a rig without it makes every code below come back 78 (cannot verify) instead
# of the 75/77/0 the assertions are about. Same class as `spawn-gate.sh` on this line.
cp "$HERE/fix-one.sh" "$HERE/spawn-gate.sh" "$HERE/chain-merge.sh" "$HERE/adopt-fix.sh" "$RO/"
cp "$HERE/brief-gate.sh" "$RO/"
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
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
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
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc0=$?
{ [ "$arc0" -eq 0 ] && grep -q PI_RAN "$PI_LOG"; }; rc=$?
ck "adopt-fix.sh reports 0 when the fixer RAN and succeeded (got $arc0) — not a constant" $rc
# ⛔ ... AND A DEFERRAL IS NOT SUCCESS EITHER (#2576, review of PR #2576 P2). `fix-one.sh` now defers
# (rc=0, nothing pushed) when a LANDER holds `mergeclaim-<PR>.lock`. `adopt-fix.sh` maps ITS OWN
# deferrals to exit 79 precisely so an operator's `adopt-fix … && next` stops; a deferral it does not
# recognise returns 0 and writes no line into `adopt-<PR>.log` — the log this wrapper exists to fill
# (#1720) — so the operator sees SUCCESS for a fixer that did nothing and a chain that ran nothing.
sleep 300 & ADOPT_LANDER=$!
printf '%s\n' "$ADOPT_LANDER" > "$RO/state/mergeclaim-7.lock"
: > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc79=$?
[ "$arc79" -eq 79 ]; rc=$?
ck "adopt-fix.sh reports a PR-OWNER deferral as 79 (got $arc79) — not SUCCESS for a run that pushed nothing" $rc
# ... and the UNUSABLE-lock refusal: also rc=0 with nothing pushed, and also invisible to an operator
# who reads only adopt-<PR>.log unless this wrapper names it.
rm -f "$RO/state/mergeclaim-7.lock"; mkdir -p "$RO/state/mergeclaim-7.lock"
: > "$PI_LOG"; : > "$MERGE_LOG"; : > "$RO/logs/adopt-7.log"; : > "$RO/logs/fix-7.log"
( cd "$RREPO" && O="$RO" FIX_TIMEOUT=5 MAX_LOAD=999999999 DISK_MIN_FREE_MB=1 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" MERGE_LOG="$MERGE_LOG" \
    bash "$HERE/adopt-fix.sh" "$RREPO" "daniel-ospina/agent-infra" 7 adoptbranch ) >/dev/null 2>&1; arc79b=$?
[ "$arc79b" -eq 79 ]; rc=$?
ck "adopt-fix.sh reports an UNUSABLE PR-owner lock as 79 (got $arc79b) — not SUCCESS" $rc
grep -q 'PR-OWNER lock, UNUSABLE' "$RO/logs/adopt-7.log"; rc=$?
ck "...and NAMES it (UNUSABLE, with the repair pointer) in the operator's log" $rc
rmdir "$RO/state/mergeclaim-7.lock" 2>/dev/null || rm -rf "$RO/state/mergeclaim-7.lock"
grep -q 'PR-OWNER lock' "$RO/logs/adopt-7.log"; rc=$?
ck "...and NAMES it in the log the operator reads" $rc
{ [ ! -s "$PI_LOG" ] && [ ! -s "$MERGE_LOG" ]; }; rc=$?
ck "...and nothing ran: no agent, no merge chain" $rc
kill "$ADOPT_LANDER" 2>/dev/null; wait "$ADOPT_LANDER" 2>/dev/null
rm -f "$RO/state/mergeclaim-7.lock"
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
# ⛔ THE LANE'S CWD IS A WORKTREE OF THE TARGET REPO, ON THE BRANCH IT IS TOLD IT IS ON
# (agent-infra#2724/#2694): lane.sh now refuses a wrong-repo worktree (72) and a worktree checked out
# on a different named branch. These arms test the LOAD/DISK gate, so the fixture satisfies both.
# ⛔ FROM THE WORKTREE THAT IS CHECKED OUT ON `work` (#2762 review, 6th cycle, P1). `$RREPO`'s HEAD is
# `main` (the fixture creates `work` as a BRANCH and materialises `.worktrees/fix-7` on it), so running
# the lane from `$RREPO` made the BRANCH assertion refuse 72 before the load gate was ever reached —
# these two arms test the LOAD gate, so the fixture must satisfy the identity gate, exactly as the DISK
# arm below already does.
( cd "$RREPO/.worktrees/fix-7" && O="$RO" MAX_LOAD=0 DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 PATH="$RIG/bin:$PATH" PI_LOG="$PI_LOG" \
    bash "$HERE/lane.sh" 9999 work daniel-ospina/agent-infra ) >/dev/null 2>&1; lrc=$?
{ [ "$lrc" -eq 75 ] && [ ! -s "$PI_LOG" ] && [ -s "$RO/logs/prompt-9999.txt" ]; }; rc=$?
ck "lane.sh on a refused load exits 75, writes the prompt, and NEVER spawns (rc=$lrc)" $rc
grep -q 'load gate refused' "$RO/logs/lane-9999.log"; rc=$?
ck "lane.sh NAMES the load gate on a load refusal" $rc
# The DISK arm: 77 propagates out of lane.sh, and the refusal line NAMES the disk gate. lane.sh is
# what opens a PR, so a lane refused here consumed nothing — but an operator told "load gate" would
# re-dispatch into the same full filesystem for ever.
: > "$PI_LOG"; : > "$RO/logs/lane-9999.log"
( cd "$RREPO/.worktrees/fix-7" && O="$RO" MAX_LOAD=999999999 DISK_MIN_FREE_MB=9999999 DISK_GATE_PATH="$RREPO" \
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
  # ⛔ THE HEADROOM GATE IS NEUTRALISED HERE (DISK_LANE_TREE_MB=0 / DISK_LANE_RESERVE_MB=0), because
  # these arms are the FLOOR's: without it a host with less free space than the shipped per-lane
  # reserve (6 GiB for a python target, 1 GiB otherwise) refuses before the floor is ever consulted,
  # and every "the floor refused" assertion would pass for a reason it does not name. The headroom
  # gate has its OWN arms below, which drive it with explicit costs.
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$path" DISK_MIN_FREE_MB="$floor" DISK_WARN_FREE_MB="$warn" \
  DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 \
  bash -c '
    . "$1"
    cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "disk gate test" >/dev/null 2>&1
    rc=$?
    printf "rc=%s started=%s" "$rc" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO"
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
band="$(DISK_MIN_FREE_MB=100 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 DISK_WARN_FREE_MB=1 bash -c '
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

# ⛔ FORK HEADROOM OUTRANKS BOTH, AND IT IS DRIVEN, NOT GREPPED (agent-infra#2293 — this section exists
# because the verification gate found the first version of the fork arm INERT: it answered `ok` on a box
# with 10 pids left, and every assertion about it was a grep). The reading is faked at its LEAVES
# (`cap_procs_live`/`cap_ulimit_u`) so the real `cap_procs_pair_vars`, the real headroom arithmetic and
# the real `spawn_fork_state` all run.
# ⛔ THE CALLER'S VARIABLE NAMES BELOW (`p m src`) ARE THE POINT, not decoration: bash `local` is
# DYNAMIC, so when this function's own locals were named `p`/`m`/`src` the `printf -v` writes landed in
# the CALLEE's locals and the caller read empty strings — the arm then answered `ok`. Pinning both name
# shapes makes that collision unrecoverable.
cap_abspath="$(cd "$HERE/.." >/dev/null 2>&1 && pwd)/orchestrator-harness/capacity.sh"
[ -f "$cap_abspath" ] || cap_abspath="$HERE/capacity.sh"
# A pair that is out of headroom (10 spare, margin 200) yet PASSES the two-fork probe — the exact
# condition the arithmetic arm exists for.
fake_edge() { # fake_edge <procs> <max> — re-declares the leaves, then reports the module's own verdict
  bash -c '
    FAKE_PROCS="$1"; FAKE_MAX="$2"
    . "$3" 2>/dev/null
    cap_procs_live() { printf "%s" "$FAKE_PROCS"; }
    cap_ulimit_u() { printf "%s" "$FAKE_MAX"; }
    cap_maxprocperuid() { return 1; }
    . "$4"
    spawn_fork_state p m src
    printf "COLLIDE:state=%s|detail=%s" "$p" "$m"
    printf " \\n"
    spawn_fork_state _dp _dm _ds
    # Two specifiers, TWO arguments: the names `_dp _dm _ds` used to be passed as well and were never
    # printed (a five-argument printf against a two-specifier format silently drops the tail, so a
    # reader of the failure output saw nothing about which variables had been driven) — review P3.
    printf "NOCLOBBER:state=%s|detail=%s" "$_dp" "$_dm"
  ' _ "$1" "$2" "$cap_abspath" "$GATE"
}
edge_out="$(fake_edge 15631 15641)"
case "$edge_out" in *"COLLIDE:state=refused"*"NOCLOBBER:state=refused"*) rc=0 ;; *) rc=1 ;; esac
ck "a box 10 pids from its ceiling is REFUSED at the spawn point even when the caller names its vars p/m/src (dynamic-scoping collision) [$edge_out]" $rc
case "$edge_out" in *"detail=headroom=10 < min_fork_headroom=200"*) rc=0 ;; *) rc=1 ;; esac
ck "...and the refusal NAMES the reading it refused (headroom, the margin, the pair) — not a bare 'busy'" $rc
ok_out="$(fake_edge 400 15641)"
case "$ok_out" in *"COLLIDE:state=ok"*) rc=0 ;; *) rc=1 ;; esac
ck "POSITIVE CONTROL: the SAME box with 15k spare pids is ALLOWED (the arm is not a blanket refusal) [$ok_out]" $rc

# END TO END through the SHIPPED run_agent: the agent really is not started, the code is the FORK
# code (74, not 77/75), and the log says why.
: > "$LOG"; : > "$PI_LOG"
run_fork() { # run_fork <procs> <max> [<max-load>] [<disk-floor>]
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD="${3:-999999999}" \
  DISK_GATE_PATH="$TMP" DISK_MIN_FREE_MB="${4:-1}" \
  bash -c '
    FAKE_PROCS="$5"; FAKE_MAX="$6"
    . "$1" 2>/dev/null
    cap_procs_live() { printf "%s" "$FAKE_PROCS"; }
    cap_ulimit_u() { printf "%s" "$FAKE_MAX"; }
    cap_maxprocperuid() { return 1; }
    . "$2"
    LOG="$3"; PROMPT="$4"
    run_agent 1 "$LOG" "$PROMPT" "fork gate test" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$cap_abspath" "$GATE" "$LOG" "$PROMPT" "$1" "$2"
}
ran="$(run_fork 15631 15641)"
[ "$ran" = "rc=73 started=0" ]; rc=$?
ck "run_agent REFUSES with the FORK code (73) on a starved box — no agent started ($ran)" $rc
grep -q 'PI_RAN' "$PI_LOG" 2>/dev/null; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and pi was really NOT invoked (the stub never ran) — not merely 'the function returned non-zero'" $rc
grep -q '\[fork-gate\] REFUSED' "$LOG"; rc=$?
ck "...and the lane log names the fork gate and its reading (an operator is not left with a bare code)" $rc
grep -q 'load-gate' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and it is NOT reported as a load refusal (the remedies differ: restart the box vs wait for load)" $rc
# ⛔ FORK OUTRANKS DISK **AND** LOAD: all three would refuse, and the fork is the un-clearable one that
# must be named first (the same precedence rule the disk-outranks-load arm above pins).
: > "$LOG"; : > "$PI_LOG"
both="$(run_fork 15631 15641 0 9999999)"
[ "$both" = "rc=73 started=0" ]; rc=$?
ck "a FORK refusal outranks a simultaneous DISK and LOAD refusal — the external-restart one is reported ($both)" $rc
# …and the positive control through the same path: plenty of pids means the agent RUNS.
: > "$LOG"; : > "$PI_LOG"
runs="$(run_fork 400 15641)"
[ "$runs" = "rc=0 started=1" ]; rc=$?
ck "POSITIVE CONTROL: with headroom the SAME drive starts the agent (rc=0) — the gate is not always closed ($runs)" $rc

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
[ "$rc" -eq 0 ] && [ "$nf" = "7" ] && [ "$f5" = "$TMP" ]; rc=$?
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

# ── THE HEADROOM GATE (agent-infra#2721) ───────────────────────────────────────────────────────────
# #2721's defect was NOT "the floor was too low": cell-4's spawns passed a floor of 500 MB with 2,286 MB
# free and still filled the disk, because the lane each of them started was going to write 5-6 GB. The
# missing instrument is the lane's OWN cost, so these arms drive IT — and they must fail on the
# pre-#2721 tree, where `DISK_LANE_TREE_MB=999999` is an unused variable and every spawn is admitted.
echo
echo "── THE HEADROOM GATE (#2721): a lane's own tree against the space it has left ──"

# drive_hd <path> <tree-mb> <reserve-mb> [<kind>] — the same rig as drive_disk, with the lane's cost
# supplied EXPLICITLY so the verdict is decided by arithmetic rather than by this host's free space.
drive_hd() { # drive_hd <path> <tree-mb> <reserve-mb> [<kind>]
  local path="$1" tree="$2" reserve="$3" kind="${4:-}"
  : > "$PI_LOG"
  PATH="$TMP/bin:$PATH" PI_LOG="$PI_LOG" O="$TMP/O" MAX_LOAD=999999999 \
  DISK_GATE_PATH="$path" DISK_MIN_FREE_MB=1 DISK_WARN_FREE_MB=9999999 \
  DISK_LANE_TREE_MB="$tree" DISK_LANE_RESERVE_MB="$reserve" KIND="$kind" \
  bash -c '
    . "$1"
    cd "$5" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    LOG="$2"; PROMPT="$3"; KIND="${4:-agent}"
    run_agent 1 "$LOG" "$PROMPT" "headroom gate test" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"
  ' _ "$GATE" "$LOG" "$PROMPT" "$kind" "$FIXREPO"
}

# POSITIVE CONTROL: a lane whose tree fits (tree 0) is ADMITTED. Without it, every refusal below
# would pass on a gate that refuses unconditionally — the inert-gate mirror of the same defect.
res="$(drive_hd "$TMP" 0 0)"; rc=$?
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a lane whose tree FITS is admitted ($res)" $rc

# THE REFUSAL, and it is NAMED with both terms. ⛔ THE TREE IS DELIBERATELY UNREACHABLE, not a real
# 6 GiB: a real figure makes the arm depend on THIS HOST's free space, so the very box most likely to
# run CI (a roomy one) would ADMIT here and report a false RED on the refusal it is supposed to pin.
# The same idiom as the unreachable floor above (`DISK_MIN_FREE_MB=9999999`).
: > "$LOG"
res="$(drive_hd "$TMP" 9999999 9999999)"; rc=$?
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "DISK-NOHEADROOM: a lane whose tree + reserve exceeds free space is REFUSED (77) and nothing starts ($res)" $rc
grep -q 'DISK-NOHEADROOM' "$LOG"; rc=$?
ck "the refusal is NAMED 'DISK-NOHEADROOM', so it is not read as the load or the floor gate" $rc
{ grep -q 'needs 9999999MB' "$LOG" && grep -q 'keep 9999999MB free' "$LOG" && grep -q '19999998MB is required' "$LOG"; }; rc=$?
ck "it states BOTH terms and their sum, so the arithmetic can be checked from the log alone" $rc
grep -q 'disk_min_free_mb=' "$LOG"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "...and it does NOT claim the floor refused: the floor is at 1MB, and the two verdicts differ" $rc
grep -q 'NOT a load refusal' "$LOG"; rc=$?
ck "...and it says waiting will not clear it, so an operator is not sent to a load remedy" $rc

# THE OTHER DIRECTION — a tree that fits is admitted even inside the WARN band, i.e. the headroom gate
# is a predicate and not a second, unconditional refusal.
res="$(drive_hd "$TMP" 1 1)"; rc=$?
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a small tree is admitted (the headroom gate is a predicate, not a blanket refusal) ($res)" $rc

# ⛔ NO EXEMPTION BY KIND — a `fixer` provisions a FRESH worktree in adopt-fix.sh, so it pays the same
# tree cost as a creation lane. Asserted in the refusing direction, because that is the claim.
: > "$LOG"
res="$(drive_hd "$TMP" 9999999 9999999 fixer)"; rc=$?
[ "$res" = "rc=77 started=0" ]; rc=$?
ck "a FIXER lane is NOT exempt from the headroom gate (it provisions a fresh worktree too) ($res)" $rc

# THE DERIVED PER-TARGET DEFAULTS (#1852's recorded finding: one global constant cannot serve an
# agent-infra lane and a tortoise lane). Driven through the shipped `disk_lane_costs`, not re-derived.
mkdir -p "$TMP/uvtarget"
printf 'version = 1\n' > "$TMP/uvtarget/uv.lock"
got="$(bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144" ]; rc=$?
ck "a target with uv.lock derives the MEASURED python pair (want '350 6144', got '${got:-<none>}')" $rc
got="$(bash -c '. "$1"; disk_lane_costs "$2"' _ "$GATE" "$TMP")"
[ "$got" = "64 1024" ]; rc=$?
ck "a target with no install step derives the harness pair (want '64 1024', got '${got:-<none>}')" $rc
got="$(bash -c '. "$1"; DISK_LANE_TREE_MB=912 DISK_LANE_RESERVE_MB=5; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "912 5" ]; rc=$?
ck "an operator OVERRIDE wins over the derived pair — a cell that measured differently can say so (got '${got:-<none>}')" $rc
got="$(bash -c '. "$1"; DISK_LANE_TREE_MB=abc DISK_LANE_RESERVE_MB=; disk_lane_costs "$2"' _ "$GATE" "$TMP/uvtarget")"
[ "$got" = "350 6144" ]; rc=$?
ck "a NON-NUMERIC override is NOT an override: it derives, so a typo cannot disarm the gate (got '${got:-<none>}')" $rc

# THE PREDICATE's boundaries, including the unreadable fail-open (it must match the floor's polarity).
bash -c '. "$1"; disk_headroom_ok 100 50 50' _ "$GATE"; rc=$?
ck "free == tree + reserve is ADMITTED (the boundary is inclusive)" $rc
bash -c '. "$1"; disk_headroom_ok 99 50 50' _ "$GATE"; rc=$?
[ "$rc" -ne 0 ]; rc=$?
ck "one MB under tree + reserve is REFUSED" $rc
bash -c '. "$1"; disk_headroom_ok "" 50 50' _ "$GATE"; rc=$?
ck "an UNREADABLE reading fails OPEN, matching disk_ok/disk_low — a probe that cannot answer is not pressure" $rc

# THE ALLOWED RUN RECORDS THE NUMBERS (fields 6-7), so "how close did we get" is answerable later.
: > "$TMP/O/state/disk.tsv"
res="$(drive_hd "$TMP" 7 11)"; rc=$?
row="$(tail -1 "$TMP/O/state/disk.tsv" 2>/dev/null)"
{ [ "$res" = "rc=0 started=1" ] && [ "$(printf '%s' "$row" | cut -f6)" = "7" ] && [ "$(printf '%s' "$row" | cut -f7)" = "11" ]; }; rc=$?
ck "an ALLOWED run records the lane's tree + reserve in disk.tsv, so the series answers 'how close' (row='${row}')" $rc

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
    cd "$4" || exit 2            # a GitHub-origin fixture: the creation gate reads THIS repo
    disk_free_mb() { printf "%s" "9.7e+15"; }
    LOG="$2"; PROMPT="$3"
    run_agent 1 "$LOG" "$PROMPT" "non-numeric probe" >/dev/null 2>&1
    printf "rc=%s started=%s" "$?" "$AGENT_STARTED"' _ "$GATE" "$LOG" "$PROMPT" "$FIXREPO")"
[ "$res" = "rc=0 started=1" ]; rc=$?
ck "a NON-NUMERIC reading fails OPEN like an empty one — it is not a claim that the disk is full ($res)" $rc
grep -q 'disk-gate.*WARN.*could not read free space' "$LOG"; rc=$?
ck "...and a NON-NUMERIC reading is ANNOUNCED too — the predicates call it unreadable, so the log must agree" $rc

# ── 12) a lane killed at its CAP keeps its work (#2045) ─────────────────────────────
# THE MEASURED DEFECT (2026-10-18): eight background lanes dispatched, THREE produced nothing, and
# one was killed at its 35-minute cap MID-WORK — 269,237 characters of transcript, seven MODIFIED
# files in its worktree, no report file, no `.rc`, and the launcher reported
# `worker finished: … commits=0 PR=none`. The work was recoverable only because a human happened to
# notice a dirty temp worktree, and nothing in the harness could tell that lane from one that
# legitimately had nothing to do: a killed lane's log is a slow lane's log.
#
# Every arm below drives the SHIPPED `run_agent` against a REAL git worktree and asserts on the
# ARTIFACTS it wrote and on whether the KILL still landed — never on a message. The two properties
# that must hold together pull in opposite directions and are pinned separately: the work is
# preserved (arms 1–5, 8) AND a worker that IGNORES SIGTERM is still hard-killed at its cap (arm 6).
# Trading the second for the first is the "a hung worker is never killed" regression the cap exists
# to prevent, so it has its own arm rather than a sentence in a comment.
CAPRIG="$TMP/caprig"; CREPO="$CAPRIG/repo"; CO="$CAPRIG/O"
mkdir -p "$CAPRIG/bin" "$CO/logs" "$CO/state" "$CREPO"
git -C "$CREPO" init -q -b main
git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'line one\n' > "$CREPO/tracked.txt"
git -C "$CREPO" add tracked.txt
git -C "$CREPO" -c user.email=t@t -c user.name=t commit -q -m "seed"
git -C "$CREPO" worktree add -q .worktrees/cap-1 -b work
CWT="$CREPO/.worktrees/cap-1"
# ⛔ THE CREATION BACK-PRESSURE GATE IS SUPPLIED A READING HERE TOO, NOT SWITCHED OFF (#2409/#2045).
# `run_agent` now measures the repo's landing ratio through `gh` immediately before any spawn, so a
# rig that supplies NEITHER a `gh` answer NOR a GitHub-origin repo is refused by the WRONG gate:
# `land_backlog_repo` cannot derive owner/name from `$CWT`'s config, the gate fails CLOSED to
# AGENT_LAND_BACKLOG (74), and every cap arm below then reads `cap_hit=0 dir=none` having never
# started a worker (measured on the integration branch: 18 red arms, all `rc=74 cap_hit=0`). This is
# the same seam, and the same rule, the `drive()` helper above already documents: an env var that
# opens a gate is not a gate, so the calm reading is put where the gate actually READS it. The gate
# itself is untouched — these arms test the CAP, not the backlog gate.
# A linked worktree shares the repository config, so this origin is what `git -C "$CWT" remote`
# answers for the arms' cwd.
git -C "$CREPO" remote add origin https://github.com/owner/repo.git
printf '#!/bin/sh\ncase "$*" in\n  *state=open*) echo 0 ;;\n  *state=closed*) : ;;\n  *) exit 1 ;;\nesac\n' > "$CAPRIG/bin/gh"
chmod +x "$CAPRIG/bin/gh"
# A worker that never finishes inside the cap. (arm 6 replaces it with one that IGNORES SIGTERM;
# the controls replace it with one that exits at once — a stub that outlives its cap cannot serve as
# the "finished in time" control, it would just be another cap hit.)
cap_stub() { # cap_stub sleep|exit0|ignoreterm
  case "$1" in
    exit0)      printf '#!/bin/sh\nexit 0\n' ;;
    ignoreterm) printf '#!/bin/bash\ntrap "" TERM\nsleep 30\n' ;;
    *)          printf '#!/bin/sh\nsleep 30\n' ;;
  esac > "$CAPRIG/bin/pi"
  chmod +x "$CAPRIG/bin/pi"
}
cap_stub sleep
cap_dirty() {   # dirty the worktree the way a real lane leaves it: a tracked edit + an untracked file
  printf 'line two — the work a cap kill used to destroy\n' >> "$CWT/tracked.txt"
  printf 'brand new analysis\n' > "$CWT/untracked-new.txt"
}
cap_clean() {   # restore the committed content WITHOUT a path-restore verb (that is the discard the
                # working-tree gate refuses in a worktree — and this suite must not do it in place)
  git -C "$CWT" show HEAD:tracked.txt > "$CWT/tracked.txt"
  rm -f "$CWT/untracked-new.txt"
}
# drive_cap <cap-s> <label> [<cwd>] [<wip-path>] — the shipped run_agent, load1 re-declared (the same
# seam every other section uses), DISK_MIN_FREE_MB=1 and the headroom gate neutralised so the disk gate cannot decide an arm.
drive_cap() { # drive_cap <cap-s> <label> [cwd] [wip-path]
  local cap="$1" label="$2" cwd="${3:-$CWT}" wip="${4:-}"
  PATH="$CAPRIG/bin:$PATH" O="$CO" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 WIP_PATH="$wip" bash -c '
    . "$1"
    # ⛔ UNSET THE EXPORTED `pi` FUNCTION FIRST. Section 9 exports one (`export -f pi`) because a
    # function beats a caller-s own PATH prepend, and an exported function arrives in EVERY child
    # bash — including this one. Left in place it would shadow the FILE stub these arms need, abort
    # on its own unbound $PI_LOG under `set -u`, and return 127 instantly: every cap arm below then
    # reads `cap_hit=0` for a reason that has nothing to do with the code under test (measured: 15
    # red arms, all rc=127). This is the same shadowing class the #1828 comment inside section 9
    # documents, from the other direction. (NO APOSTROPHES inside this body: it is a single-quoted
    # `bash -c` string, and one of them silently ends it.)
    unset -f pi 2>/dev/null || true
    MAX_LOAD=999999999; load1() { printf "0"; }
    cd "$2" || exit 9
    run_agent "$3" "$4" "$5" "$6" >/dev/null 2>&1
    rc=$?
    # `${AGENT_CAP_HIT:-0}` — TOLERANT ON PURPOSE. On a tree without the fix these globals do not
    # exist, and under `set -u` a bare reference would abort the arm with `unbound variable`: every
    # red would then be a test error rather than the defect, and the pre-fix reading (a cap kill that
    # reports NOTHING) would never be printed. With the default, the pre-fix run says
    # `cap_hit=0 dir=none` on a run that demonstrably hit its cap — which IS the defect, stated.
    printf "rc=%s cap_hit=%s dir=%s result=%s" "$rc" "${AGENT_CAP_HIT:-0}" "${WIP_SNAPSHOT_DIR:-none}" "${WIP_SNAPSHOT_RESULT:-none}"
  ' _ "$GATE" "$cwd" "$cap" "$CO/logs/cap.log" "$PROMPT" "$label"
}

: > "$CO/logs/cap.log"; rm -rf "$CO/wip" "$CO/state/capwip.tsv"
cap_clean; cap_dirty
res="$(drive_cap 2 "capped lane")"
case "$res" in *"cap_hit=1"*) rc=0 ;; *) rc=1 ;; esac
ck "a run that reaches its cap sets AGENT_CAP_HIT=1 — a caller signal, never an inferred exit code ($res)" $rc
snap="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$res")"
{ [ "$snap" != "none" ] && [ -d "$snap" ]; }; rc=$?
ck "the cap wrote a snapshot directory ($snap)" $rc
# THE ARTIFACT, RE-PARSED. "a file exists" is the false PASS this repo keeps removing: the patch
# must PARSE as a patch and COVER the tracked change.
if [ -f "$snap/tracked.patch" ] && git -C "$CWT" apply --numstat "$snap/tracked.patch" > "$CAPRIG/ns" 2>/dev/null; then rc=0; else rc=1; fi
ck "…whose tracked.patch git apply can PARSE (re-verified, not assumed)" $rc
grep -q 'tracked\.txt' "$CAPRIG/ns" 2>/dev/null; rc=$?
ck "…and it covers the tracked edit the kill interrupted" $rc
# THE REPLAY, DRIVEN. A parse check alone passes on a patch that parses and cannot apply.
if [ -f "$snap/tracked.patch" ]; then
  EXPECT="$(cat "$CWT/tracked.txt")"
  cap_clean                       # back to the committed content: a replay target
  ( cd "$CWT" && git apply "$snap/tracked.patch" ) >/dev/null 2>&1; arc=$?
  { [ "$arc" -eq 0 ] && [ "$(cat "$CWT/tracked.txt")" = "$EXPECT" ]; }; rc=$?
  ck "…and applying it to a reverted file RESTORES the work byte for byte (rc=$arc) — the replay is real" $rc
else
  ck "…and applying it to a reverted file RESTORES the work byte for byte (no patch was written)" 1
fi
if [ -f "$snap/untracked.tgz" ]; then
  grep -qx 'untracked-new.txt' <<<"$(tar -tzf "$snap/untracked.tgz" 2>/dev/null)"; rc=$?
  ck "…the untracked file is in untracked.tgz (an untracked file is work too)" $rc
else
  ck "…the untracked file is in untracked.tgz (no archive was written)" 1
fi
{ [ -f "$snap/SNAPSHOT.txt" ] && grep -qx 'result=COMPLETE' "$snap/SNAPSHOT.txt"; }; rc=$?
ck "…SNAPSHOT.txt records result=COMPLETE, and COMPLETE means VERIFIED (patch parsed, archive listed)" $rc
# The LEDGER row is what a later session reads instead of scrolling logs; the LOG line is what an
# operator reading the lane's own log sees. Both must name the cap and the preserved directory.
{ [ -s "$CO/state/capwip.tsv" ] && grep -q 'capped lane' "$CO/state/capwip.tsv"; }; rc=$?
ck "a capwip.tsv row records the label, the cap and the snapshot (the fleet's own accounting)" $rc
grep -q '\[cap\].*KILLED AT ITS 2s CAP.*work PRESERVED (COMPLETE)' "$CO/logs/cap.log"; rc=$?
ck "the log says KILLED AT ITS CAP and names the preserved work — not silence" $rc
grep -q '\[cap\]   replay:' "$CO/logs/cap.log"; rc=$?
ck "…and prints the exact replay command, so recovering the work needs no guesswork" $rc

# ⛔ CONTROL: a run that finishes BELOW the cap writes NOTHING. Without this, the arms above pass on
# a tree that snapshots on EVERY run — slow, disk-hungry, and firing on healthy lanes.
: > "$CO/logs/cap.log"; rm -rf "$CO/wip"
cap_stub exit0
res="$(drive_cap 30 "finished in time")"
[ "$res" = "rc=0 cap_hit=0 dir=none result=none" ]; rc=$?
ck "CONTROL: a run that finishes below its cap sets cap_hit=0 and writes NO snapshot ($res)" $rc
cap_stub sleep
[ ! -e "$CO/wip" ]; rc=$?
ck "…and no wip/ directory is created at all on a healthy run" $rc
# ⛔ A CLEAN TREE AT THE CAP IS NOT A LOSS, AND IT MUST STILL SAY SO. "the tree was clean" and "the
# work was saved" are DIFFERENT FACTS, and their being indistinguishable IS the defect: both used to
# read as `commits=0`. One `[cap]` line each; only the second mentions artifacts.
: > "$CO/logs/cap.log"; cap_clean
res="$(drive_cap 1 "clean at the cap")"
case "$res" in *"cap_hit=1 dir=none"*) rc=0 ;; *) rc=1 ;; esac
ck "a cap hit on a CLEAN worktree reports cap_hit=1 with no snapshot ($res)" $rc
grep -q '\[cap\].*was CLEAN, so NOTHING WAS LOST' "$CO/logs/cap.log"; rc=$?
ck "…and says NOTHING WAS LOST, so a clean cap is distinguishable from a lost one" $rc
# ⛔ THE KILL STILL LANDS. A worker that IGNORES SIGTERM must be SIGKILLed at the cap — the snapshot
# runs AFTER `wait`, so it can never hold the process open. This is the arm that catches a future
# "checkpoint grace period" that quietly turns the cap into advisory.
cap_stub ignoreterm
: > "$CO/logs/cap.log"; rm -rf "$CO/wip"; cap_clean; cap_dirty
h0="$(date +%s)"
res="$(drive_cap 1 "ignores SIGTERM")"
h1="$(date +%s)"; took=$((h1 - h0))
case "$res" in *"cap_hit=1 dir="*) rc=0 ;; *) rc=1 ;; esac
ck "a worker that IGNORES SIGTERM is still killed at its cap and its work is still snapshotted ($res)" $rc
# A hard kill is a SIGNAL exit status; a clean finish is 0. Asserting the polarity, not a literal,
# because 143 (TERM) and 137 (KILL) are both correct depending on whether the worker trapped TERM.
case "$res" in *"rc=0 "*) rcbad=1 ;; *"rc="*) rcbad=0 ;; *) rcbad=1 ;; esac
ck "…and the run's exit status is NON-ZERO (a hard kill, not a clean finish): $res" $rcbad
# The watchdog budget is cap + 15 s grace + a little. THE LOWER BOUND IS THE DISCRIMINATOR: a
# worker that HONOURED the SIGTERM would be gone in ~1 s, so a run that takes less than the grace
# proves the trap was ignored — and one that finishes inside the upper bound proves the SIGKILL then
# landed. Without both, this arm passes on a worker that simply died early.
{ [ "$took" -ge 14 ] && [ "$took" -le 40 ]; }; rc=$?
ck "…and the run took ${took}s (cap 1s + the 15s grace): the SIGTERM was IGNORED and the SIGKILL still landed" $rc
cap_stub sleep
# ⛔ AND THE WORKTREE IS NAMED, NOT ASSUMED. fix-one.sh `cd`s into the MAIN checkout while its work
# lives in the fixer's worktree, so run_agent's `$PWD` default would snapshot the wrong tree and
# report CLEAN while the fixer's work sat unsaved one directory away — a loud, WRONG verdict, which
# is worse than no snapshot. `WIP_PATH` is that caller's answer, so drive it: cwd is the clean main
# checkout, the dirty tree is the worktree, and the snapshot must be the WORKTREE's.
: > "$CO/logs/cap.log"; rm -rf "$CO/wip"; cap_clean; cap_dirty
res="$(drive_cap 2 "fixer shape" "$CREPO" "$CWT")"
snap="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$res")"
{ [ "$snap" != "none" ] && [ -f "$snap/tracked.patch" ] && grep -q 'tracked\.txt' "$snap/tracked.patch"; }; rc=$?
ck "WIP_PATH names the tree whose work is at risk: a cap kill with cwd in the MAIN checkout snapshots the FIXER's worktree ($res)" $rc

# ⛔ THE ONLY DESTRUCTIVE PRIMITIVE GETS ITS OWN ARM (review cycle 2: the retention loop `rm -rf`s, and
# nothing in the suite touched it). "it reads correctly" is not evidence for a delete: a wrong glob
# here is silent data loss. Fixtures: 12 `capwip-*` directories (2 must go), a SIBLING capture from
# another feature (never ours to remove), and a FILE that matches the prefix but is not a directory.
PW="$CAPRIG/prune"; rm -rf "$PW"; mkdir -p "$PW"
i=0; while [ "$i" -lt 12 ]; do mkdir -p "$PW/capwip-20260101-1$i"; i=$((i + 1)); done
mkdir -p "$PW/other-capture"
printf 'not a directory\n' > "$PW/capwip-notadir"
bash -c '. "$1"; WIP_SNAPSHOT_KEEP=10; cap_wip_prune "$2"' _ "$GATE" "$PW"
pdirs=0
for d in "$PW"/capwip-*/; do [ -d "$d" ] && pdirs=$((pdirs + 1)); done
[ "$pdirs" -eq 10 ]; rc=$?
ck "cap_wip_prune keeps exactly WIP_SNAPSHOT_KEEP capwip DIRECTORIES out of 12 (kept=$pdirs)" $rc
{ [ -d "$PW/other-capture" ] && [ -f "$PW/capwip-notadir" ]; }; rc=$?
ck "…and removes NOTHING that is not a capwip-* directory (a sibling capture and a same-prefix FILE both survive)" $rc

# ⛔ THE ABSENCE BRANCHES ARE VERDICTS TOO (VGATE cycle 3, F2). `WIP_SNAPSHOT_RESULT` used to be
# EMPTY when no snapshot could be taken, and the launcher read an empty verdict as "the worktree was
# CLEAN, nothing was lost" — so a cap kill on a FULL DISK (the leading cell failure mode) would have
# announced that nothing was lost over work that existed only in a worktree about to be reaped. That
# is #2045's own defect, one layer up. Every failure mode must name itself, and both are driven here.
FB="$CAPRIG/failbranch"; mkdir -p "$FB/notagit"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" bash -c '
  . "$1"
  WIP_PATH="$2" cap_wip_snapshot "not a repo" 5 5 143 "$3" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/notagit" "$FB/log")"
[ "$fb" = "rc=1 result=UNSNAPSHOTABLE" ]; rc=$?
ck "a cap kill outside a git worktree returns 1 with result=UNSNAPSHOTABLE, never an empty verdict ($fb)" $rc
# A wip path that is a FILE makes `mkdir -p` fail the same way a full disk does — and it fails for
# root too, which a chmod-based fixture would not.
mkdir -p "$FB/O/state"; printf 'not a dir\n' > "$FB/O/wip"
cap_clean; cap_dirty
fb="$(PATH="$CAPRIG/bin:$PATH" O="$FB/O" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "disk full" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log")"
[ "$fb" = "rc=1 result=LOST" ]; rc=$?
ck "…and a dirty tree it CANNOT write returns 1 with result=LOST (a full disk is not 'nothing was lost') ($fb)" $rc
grep -q 'COULD NOT BE CREATED.*LOST if the worktree is reaped' "$FB/log"; rc=$?
ck "…and says so loudly in the log, naming the one remaining copy" $rc

# ⛔ A SNAPSHOT MUST NEVER CLAIM COMPLETE OVER NOTHING (VGATE cycle 5). Two shapes the two COUNTS
# cannot see, both measured on the shipped code before this arm existed:
#   (1) an UNBORN branch — `git init` + a staged file and no commit yet: `git diff HEAD` exits 128, so
#       both counts read 0 while `status --porcelain` reports a modification, and the verdict was
#       COMPLETE over a 0-byte patch (the log contradicted itself on one line: "work PRESERVED" over
#       "tracked=0 path(s) -> tracked.patch (0 bytes, verified=0)");
#   (2) an UNMERGED index — what `git merge` leaves mid-conflict, i.e. a fixer resolving conflicts, the
#       exact caller that passes WIP_PATH. `git diff HEAD` then emits a BOGUS new-file diff that
#       `git apply --numstat` parses happily, so parse-only "verification" passed while the replay the
#       log prints fails with "already exists in working directory".
UNB="$CAPRIG/unborn"; rm -rf "$UNB"; git init -q "$UNB"
printf 'precious\n' > "$UNB/precious.txt"; git -C "$UNB" add precious.txt
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UNB" bash -c '
  . "$1"
  cap_wip_snapshot "unborn branch" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log2")"
[ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
ck "an UNBORN branch (dirty tree, no HEAD to diff) is PARTIAL, never COMPLETE over a 0-byte patch ($fb)" $rc
# A real conflict, built the way git builds one, so the fixture cannot be fake.
CFL="$CAPRIG/conflict"; rm -rf "$CFL"; git init -q -b main "$CFL"
printf 'base\n' > "$CFL/f.txt"; git -C "$CFL" add f.txt
git -C "$CFL" -c user.email=t@t -c user.name=t commit -q -m base
git -C "$CFL" checkout -q -b side
printf 'side\n' > "$CFL/f.txt"
git -C "$CFL" -c user.email=t@t -c user.name=t commit -q -am side
git -C "$CFL" checkout -q main
printf 'main\n' > "$CFL/f.txt"
git -C "$CFL" -c user.email=t@t -c user.name=t commit -q -am main
git -C "$CFL" -c user.email=t@t -c user.name=t merge side >/dev/null 2>&1
[ -n "$(git -C "$CFL" ls-files --unmerged)" ]; rc=$?
ck "FIXTURE: the worktree really is mid-conflict (unmerged index stages exist)" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$CFL" bash -c '
  . "$1"
  cap_wip_snapshot "mid conflict" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log3")"
[ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
ck "an UNMERGED index (the resolution is in NO artifact) is PARTIAL, never COMPLETE ($fb)" $rc

# ⛔ CANNOT-VERIFY IS NOT CLEAN (VGATE cycle 6). A `git status` that cannot RUN must never take the
# NOTHING-LOST branch — the repo's own ruling for this exact call (cloud-cell-supervisor.sh
# `stamp_write`: "a `git status` that cannot run (corrupt index, ENOSPC, EACCES, safe.directory) is
# CANNOT-VERIFY, never clean"). Two shapes, both measured against the shipped code, both of which
# reported NOTHING-LOST over real uncommitted work: an unreadable `.git/index` (status exits 128 with
# empty stdout) and an unreadable UNTRACKED DIRECTORY (status exits 0 with only a
# `warning: could not open directory` and empty stdout).
if [ "$(id -u)" -eq 0 ]; then
  echo "  ⏭  skip: running as root, so a chmod-000 fixture cannot make git fail"
else
  UC="$CAPRIG/unreadable-index"; rm -rf "$UC"; git init -q -b main "$UC"
  printf 'base\n' > "$UC/f.txt"; git -C "$UC" add f.txt
  git -C "$UC" -c user.email=t@t -c user.name=t commit -q -m base
  printf 'PRECIOUS UNCOMMITTED WORK\n' >> "$UC/f.txt"
  chmod 000 "$UC/.git/index"
  fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UC" bash -c '
    . "$1"
    cap_wip_snapshot "unreadable index" 5 5 143 "$2" >/dev/null 2>&1
    printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
  ' _ "$GATE" "$FB/log4")"
  chmod 644 "$UC/.git/index" 2>/dev/null || true
  [ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
  ck "an UNREADABLE .git/index (status cannot run) is PARTIAL, never 'nothing was lost' ($fb)" $rc
  UD="$CAPRIG/unreadable-dir"; rm -rf "$UD"; git init -q -b main "$UD"
  printf 'base\n' > "$UD/f.txt"; git -C "$UD" add f.txt
  git -C "$UD" -c user.email=t@t -c user.name=t commit -q -m base
  mkdir -p "$UD/notes"; printf 'work one\n' > "$UD/notes/a.md"; printf 'work two\n' > "$UD/notes/b.md"
  chmod 000 "$UD/notes"
  fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UD" bash -c '
    . "$1"
    cap_wip_snapshot "unreadable dir" 5 5 143 "$2" >/dev/null 2>&1
    printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
  ' _ "$GATE" "$FB/log5")"
  chmod 755 "$UD/notes" 2>/dev/null || true
  [ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
  ck "an UNREADABLE untracked directory (status warns, exits 0) is PARTIAL, never 'nothing was lost' ($fb)" $rc
fi

# ⛔ AND A DIRTY SUBMODULE (VGATE cycle 7). `git diff HEAD` records only `Subproject commit <sha>-dirty`,
# so a submodule's own uncommitted content is in NO artifact — while the verdict said COMPLETE. The
# probe that was supposed to catch it was INERT: `git submodule status` does not annotate content
# (`modified content` is a `git status` phrase), so it printed ` c1fec47 sub (heads/main)` and counted
# zero. The state now comes from `git status --porcelain=v2`'s `<c><m><u>` field, and BOTH arms below
# are driven — the dirty submodule, and a gitlink whose `.gitmodules` mapping is broken (which made
# `git submodule status` fatal, blinding it for every submodule in the repo).
SUB="$CAPRIG/subsrc"; SM="$CAPRIG/subparent"
rm -rf "$SUB" "$SM"; git init -q -b main "$SUB"
printf 's\n' > "$SUB/s.txt"; git -C "$SUB" add s.txt
git -C "$SUB" -c user.email=t@t -c user.name=t commit -q -m s
git init -q -b main "$SM"
printf 'p\n' > "$SM/p.txt"; git -C "$SM" add p.txt
git -C "$SM" -c user.email=t@t -c user.name=t commit -q -m p
git -C "$SM" -c protocol.file.allow=always -c user.email=t@t -c user.name=t submodule add -q "$SUB" sub >/dev/null 2>&1
git -C "$SM" -c user.email=t@t -c user.name=t commit -q -m sub >/dev/null 2>&1
printf 'uncommitted submodule work\n' > "$SM/sub/UNCOMMITTED-WORK.txt"
[ -d "$SM/sub" ] && [ -f "$SM/.gitmodules" ]; rc=$?
ck "FIXTURE: a real submodule with uncommitted content exists (else the two arms below prove nothing)" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$SM" bash -c '
  . "$1"
  cap_wip_snapshot "dirty submodule" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log6")"
[ "$fb" = "rc=1 result=PARTIAL" ]; rc=$?
ck "a DIRTY SUBMODULE (its content is in no artifact) is PARTIAL, never COMPLETE ($fb)" $rc
# A gitlink with no .gitmodules mapping: `git submodule status` is FATAL here (rc=128), so a probe built
# on it is blinded for every submodule in the repo — the inert-enforcer shape.
GH="$CAPRIG/ghostgitlink"; rm -rf "$GH"; git init -q -b main "$GH"
printf 'g\n' > "$GH/g.txt"; git -C "$GH" add g.txt
git -C "$GH" -c user.email=t@t -c user.name=t commit -q -m g
git -C "$GH" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,ghost
printf 'x\n' > "$GH/other.txt"
grep -q 'ghost' <<<"$(git -C "$GH" status --porcelain=v2 --ignore-submodules=none 2>&1)"; rc=$?
ck "FIXTURE: the ghost gitlink really appears in the porcelain=v2 read (else the arm below is vacuous)" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$GH" bash -c '
  . "$1"
  cap_wip_snapshot "ghost gitlink" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log7")"
case "$fb" in *result=COMPLETE*) rc=1 ;; *result=PARTIAL*) rc=0 ;; *) rc=1 ;; esac
# NO BACKTICKS IN THIS MESSAGE: it is double-quoted, so `git submodule status` inside it is EXECUTED
# while the message is built — measured, the failure line read "(fatal to )" (VGATE cycle 8, P2).
ck "a GHOST GITLINK (no .gitmodules mapping, which is fatal to the submodule-status call) is PARTIAL, not COMPLETE ($fb)" $rc

# ⛔ AND `status.showUntrackedFiles=no` MUST NOT DISABLE THE LEG (VGATE cycle 8, B2). It is a LEGAL
# repo/global config under which `git status` hides untracked work: the read answered "clean", the leg
# returned early with NOTHING-LOST and wrote NO snapshot at all, while `git ls-files --others` still
# listed the work. `-uall` on the read is the fix, and this arm pins it by setting that config in the
# fixture repo — a config must not be able to turn a safety leg off in the reassuring direction.
SUO="$CAPRIG/ignore-untracked"; rm -rf "$SUO"; git init -q -b main "$SUO"
printf 'base\n' > "$SUO/f.txt"; git -C "$SUO" add f.txt
git -C "$SUO" -c user.email=t@t -c user.name=t commit -q -m base
git -C "$SUO" config status.showUntrackedFiles no
printf 'UNTRACKED WORK\n' > "$SUO/UNTRACKED-WORK.txt"
grep -q 'UNTRACKED-WORK' <<<"$(git -C "$SUO" ls-files --others --exclude-standard)"; rc=$?
ck "FIXTURE: the untracked file exists and git ls-files sees it" $rc
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$SUO" bash -c '
  . "$1"
  cap_wip_snapshot "showUntrackedFiles=no" 5 5 143 "$2" >/dev/null 2>&1
  rc1=$?
  printf "rc=%s result=%s dir=%s" "$rc1" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log8")"
case "$fb" in *"result=COMPLETE"*) rc=0 ;; *) rc=1 ;; esac
ck "an untracked file is CAPTURED even with status.showUntrackedFiles=no (the leg is not disabled by a config) ($fb)" $rc
sd="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
grep -qx 'UNTRACKED-WORK.txt' <<<"$(tar -tzf "$sd/untracked.tgz" 2>/dev/null)"; rc=$?
ck "…and the work is really IN the archive, not merely counted" $rc

# ⛔ AND AN ORDINARY NAME MUST NOT PRODUCE A FALSE PARTIAL (VGATE cycle 9, F1). The dirty-path reader
# once used awk's `split($0, f, " ")`, which inherits the special single-space rule: it COLLAPSES runs
# of spaces and DROPS leading blanks, so `two  spaces.txt` and ` lead.txt` differed from their archived
# forms, `comm` reported them uncovered, and a FULLY PRESERVED snapshot said PARTIAL — an operator told
# "do NOT reap" over work that was saved. Extraction is byte-exact (`index`/`substr`) now.
SP="$CAPRIG/spaced"; rm -rf "$SP"; git init -q -b main "$SP"
printf 'base\n' > "$SP/f.txt"; git -C "$SP" add f.txt
git -C "$SP" -c user.email=t@t -c user.name=t commit -q -m base
printf 'one\n' > "$SP/two  spaces.txt"
printf 'two\n' > "$SP/ lead.txt"
printf 'three\n' > "$SP/plain.txt"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$SP" bash -c '
  . "$1"
  cap_wip_snapshot "spaced names" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log9")"
case "$fb" in *"result=COMPLETE"*) rc=0 ;; *) rc=1 ;; esac
ck "paths with a DOUBLE SPACE and a LEADING SPACE still read COMPLETE (no false 'do NOT reap') ($fb)" $rc
sd="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
{ grep -qx 'two  spaces.txt' <<<"$(tar -tzf "$sd/untracked.tgz" 2>/dev/null)" \
  && grep -qx ' lead.txt' <<<"$(tar -tzf "$sd/untracked.tgz" 2>/dev/null)"; }; rc=$?
ck "…and both names are in the archive BYTE-EXACT (so the COMPLETE above is not vacuous)" $rc

# ⛔ AND A COMPARATOR THAT CANNOT RUN MUST NOT READ AS 'FULLY COVERED' (VGATE cycle 9, F3). With `comm`
# broken/absent the uncovered set is EMPTY, which the old code read as "everything is covered" — the
# silent false PASS this leg exists to prevent. A non-zero status from sort/comm now caps the verdict.
BAD="$CAPRIG/badcomm"; mkdir -p "$BAD"
printf '#!/bin/sh\nexit 1\n' > "$BAD/comm"; chmod +x "$BAD/comm"
cap_clean; cap_dirty
fb="$(PATH="$BAD:$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "broken comparator" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log10")"
case "$fb" in *"result=PARTIAL"*) rc=0 ;; *) rc=1 ;; esac
ck "a comm that CANNOT RUN is PARTIAL, never a silent fully-covered answer ($fb)" $rc

# ⛔ AND A BROKEN PARSER MUST NOT READ AS 'THE TREE WAS CLEAN' (VGATE cycle 10, F1). `n_dirty` defaults
# to 0 and 0 is the PERMISSIVE answer — it short-circuits to NOTHING-LOST before any artifact exists.
# A broken `awk` (no awk on PATH, a shadowing script, a broken build) used to produce exactly that on a
# tree with two dirty paths. This stub is the same class as the broken-`comm` arm above, aimed at the
# tool that decides ALL FOUR values.
BADW="$CAPRIG/badawk"; mkdir -p "$BADW"
printf '#!/bin/sh\nexit 1\n' > "$BADW/awk"; chmod +x "$BADW/awk"
cap_clean; cap_dirty
fb="$(PATH="$BADW:$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "broken awk" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s" "$?" "$WIP_SNAPSHOT_RESULT"
' _ "$GATE" "$FB/log11")"
case "$fb" in *"result=NOTHING-LOST"*) rc=1 ;; *"result=PARTIAL"*) rc=0 ;; *) rc=1 ;; esac
ck "a broken awk does NOT report NOTHING-LOST — a failed parse is work-at-risk ($fb)" $rc

# ⛔ AND AN ORDINARY NON-ASCII NAME MUST LAND IN THE ARCHIVE (VGATE cycle 10, F3). The line-oriented
# `git ls-files --others` QUOTES such a name (`an\303\241lisis.md`), `tar -T` cannot stat it, and the
# file is silently MISSING while the verdict still counted other names. For a Spanish-language repo
# `análisis.md` is an ordinary filename, not an edge case. NUL-delimited names are passed through
# unquoted now.
AC="$CAPRIG/accents"; rm -rf "$AC"; git init -q -b main "$AC"
printf 'base\n' > "$AC/f.txt"; git -C "$AC" add f.txt
git -C "$AC" -c user.email=t@t -c user.name=t commit -q -m base
printf 'contenido\n' > "$AC/análisis.md"
printf 'plain\n' > "$AC/plain.md"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$AC" bash -c '
  . "$1"
  cap_wip_snapshot "accented name" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log12")"
ad="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
{ grep -qx 'análisis.md' <<<"$(tar -tzf "$ad/untracked.tgz" 2>/dev/null)" \
  && grep -qx 'plain.md' <<<"$(tar -tzf "$ad/untracked.tgz" 2>/dev/null)"; }; rc=$?
ck "a NON-ASCII untracked name is IN the archive (byte-exact), beside the ASCII one ($fb)" $rc
case "$fb" in *"result=COMPLETE"*) rc=0 ;; *) rc=1 ;; esac
ck "…and the verdict is COMPLETE, not a false PARTIAL for a Spanish filename ($fb)" $rc

# ⛔ AND A NAME BEGINNING WITH `-` MUST NOT BE READ AS A TAR OPTION (VGATE cycle 10, F3). GNU tar parses
# a `-T` line starting with `-` as an option: `-C..` silently redirects tar's directory and the count
# still "verifies" — an archive that is not the worktree's, reported as complete. Names are passed
# verbatim now, so the file is captured as a FILE.
DS="$CAPRIG/dashname"; rm -rf "$DS"; git init -q -b main "$DS"
printf 'base\n' > "$DS/f.txt"; git -C "$DS" add f.txt
git -C "$DS" -c user.email=t@t -c user.name=t commit -q -m base
printf 'dash\n' > "$DS/-C.."
printf 'normal\n' > "$DS/normal.txt"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$DS" bash -c '
  . "$1"
  cap_wip_snapshot "dash name" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log13")"
dd="$(sed -n 's/.*dir=\([^ ]*\).*/\1/p' <<<"$fb")"
grep -qx 'normal.txt' <<<"$(tar -tzf "$dd/untracked.tgz" 2>/dev/null)"; rc=$?
ck "a leading-dash name does not REDIRECT the archive: normal.txt is still captured ($fb)" $rc

# ⛔ AND A STASH IS NAMED WHERE THE MESSAGE WOULD OTHERWISE MISLEAD (VGATE cycle 10, F4). `git stash
# push -u` leaves a CLEAN worktree, so this leg correctly has nothing to capture — but "NOTHING WAS
# LOST" must not be read as "this repo holds nothing". `refs/stash` lives in the COMMON git dir, so it
# SURVIVES the worktree being removed (the fact using-git-worktrees warns about from the other side);
# the log now says so at the moment an operator would otherwise act on "nothing was lost".
STQ="$CAPRIG/stashed"; rm -rf "$STQ"; git init -q -b main "$STQ"
printf 'base\n' > "$STQ/f.txt"; git -C "$STQ" add f.txt
git -C "$STQ" -c user.email=t@t -c user.name=t commit -q -m base
printf 'hidden work\n' >> "$STQ/f.txt"
git -C "$STQ" -c user.email=t@t -c user.name=t stash push -q -u -m probe >/dev/null 2>&1
[ -z "$(git -C "$STQ" status --porcelain)" ] && git -C "$STQ" rev-parse --verify -q refs/stash >/dev/null 2>&1; rc=$?
ck "FIXTURE: the worktree is clean and a stash exists (else the arm below proves nothing)" $rc
: > "$FB/log14"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$STQ" bash -c '
  . "$1"
  cap_wip_snapshot "stashed work" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log14")"
case "$fb" in *"result=NOTHING-LOST"*) rc=0 ;; *) rc=1 ;; esac
ck "a CLEAN worktree with a stash is NOTHING-LOST for the worktree ($fb)" $rc
grep -q 'this repo has a stash' "$FB/log14"; rc=$?
ck "…and the log NAMES the stash, so 'nothing was lost' is not read as 'this repo holds nothing'" $rc

# ⛔ AND THE REPLAY LINE MUST NOT NAME AN ARCHIVE THAT WAS NEVER CREATED (VGATE cycle 11/12). A dirty
# tree with NO untracked work has no tarball, and naming one sends an operator to a command that cannot
# work at the moment they are rescuing work. IT NEEDS ITS OWN FIXTURE: the stash arm above is a CLEAN
# tree, which takes the NOTHING-LOST branch and returns before any replay line exists (the first version
# of this arm grepped that log and was structurally unpassable — a red gate over a test-wiring defect).
RT="$CAPRIG/trackedonly"; rm -rf "$RT"; git init -q -b main "$RT"
printf 'base\n' > "$RT/f.txt"; git -C "$RT" add f.txt
git -C "$RT" -c user.email=t@t -c user.name=t commit -q -m base
printf 'more work\n' >> "$RT/f.txt"
: > "$FB/log15"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$RT" bash -c '
  . "$1"
  cap_wip_snapshot "tracked only" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log15")"
grep -q 'no untracked files were present' "$FB/log15"; rc=$?
ck "a dirty tree with NO untracked work says so, instead of naming a tarball that does not exist ($fb)" $rc
cl="$(awk '/replay:/ && /untracked\.tgz/ {n++} END{print n+0}' "$FB/log15")"
[ "$cl" -eq 0 ]; rc=$?
ck "…and its replay line does not mention untracked.tgz at all" $rc

# ⛔ A LEDGER ROW ON EVERY VERDICT (review finding, P2). `state/capwip.tsv` is the fleet's own record of
# cap kills, and it used to gain a row only on the fall-through path: a CLEAN cap kill, a `LOST`
# snapshot (the full-disk case) and an `UNSNAPSHOTABLE` one (a mis-pointed WIP_PATH) left NO trace, so a
# later session reading only the ledger could not tell "cap kill, nothing lost" from "no cap kill" — the
# absence-reads-as-fine defect this whole leg exists to remove. Each verdict is driven and its row read
# back.
LEDGER="$CAPRIG/ledger/O"; rm -rf "$CAPRIG/ledger"
ledger_count() { wc -l < "$LEDGER/state/capwip.tsv" 2>/dev/null | tr -d ' '; }
cap_clean
PATH="$CAPRIG/bin:$PATH" O="$LEDGER" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "clean verdict" 5 5 143 "$2" >/dev/null 2>&1
' _ "$GATE" "$FB/log16"
grep -q 'NOTHING-LOST' "$LEDGER/state/capwip.tsv" 2>/dev/null; rc=$?
ck "a CLEAN cap kill WRITES a ledger row (verdict NOTHING-LOST), so 'nothing lost' is not an absence" $rc
mkdir -p "$CAPRIG/ledger2/O/state"; printf 'not a dir\n' > "$CAPRIG/ledger2/O/wip"; cap_dirty
PATH="$CAPRIG/bin:$PATH" O="$CAPRIG/ledger2/O" WIP_PATH="$CWT" bash -c '
  . "$1"
  cap_wip_snapshot "lost verdict" 5 5 143 "$2" >/dev/null 2>&1
' _ "$GATE" "$FB/log17"
grep -q 'LOST' "$CAPRIG/ledger2/O/state/capwip.tsv" 2>/dev/null; rc=$?
ck "…and so does a FAILED snapshot (verdict LOST) — the full-disk case leaves a trace, not silence" $rc
mkdir -p "$CAPRIG/ledger3/O/state" "$CAPRIG/notarepo3"
PATH="$CAPRIG/bin:$PATH" O="$CAPRIG/ledger3/O" WIP_PATH="$CAPRIG/notarepo3" bash -c '
  . "$1"
  cap_wip_snapshot "unsnapshottable verdict" 5 5 143 "$2" >/dev/null 2>&1
' _ "$GATE" "$FB/log18"
grep -q 'UNSNAPSHOTABLE' "$CAPRIG/ledger3/O/state/capwip.tsv" 2>/dev/null; rc=$?
ck "…and a mis-pointed WIP_PATH leaves a row too (verdict UNSNAPSHOTABLE)" $rc
n_rows="$(awk 'END{print NR+0}' "$LEDGER/state/capwip.tsv" 2>/dev/null)"
[ "${n_rows:-0}" -eq 1 ]; rc=$?
ck "…exactly one row per kill, not one per path (clean kill wrote ${n_rows:-0} row(s))" $rc

# ⛔ AND THE STATE READ MUST NOT TAKE AN OPTIONAL LOCK. `git status` refreshes the stat cache under
# `.git/index.lock`; on a worktree with a surviving orphaned writer (declared residual) that lock can
# make the LIVE writer's next git command fail — a failure the rescue would have introduced. The read
# carries `--no-optional-locks` (measured: the index mtime moves on a plain `git status` and not with
# the flag). Structural, because the alternative is racing a real writer.
grep -q -- '--no-optional-locks status --porcelain=v2' "$GATE"; rc=$?
ck "the worktree state read carries --no-optional-locks (a rescue must not interpose a lock on a live writer)" $rc

# ⛔ CONTAINMENT IS A FULL-PATH TEST, NOT A BASENAME TEST (review finding, P2 — reproduced). The prune
# list is consumed line by line, so a `capwip-*` directory whose name contains a NEWLINE arrives as two
# fragments: the first is not a directory, and the second (`capwip-victim`) was resolved relative to the
# CALLER'S CWD and DELETED — the only destructive primitive in this leg deleting an unrelated directory
# outside the wip root. The victim here sits in the cwd the prune runs from, exactly the shape measured.
PN="$CAPRIG/prune-newline"; rm -rf "$PN"; mkdir -p "$PN/wip" "$PN/cwd"
i=0; while [ "$i" -lt 12 ]; do mkdir -p "$PN/wip/capwip-keep-$i"; i=$((i + 1)); done
# ⛔ THE NEWLINE ENTRY MUST SORT AFTER THE KEEP BUDGET, or this arm is VACUOUS (verification finding):
# `ls -1dt` lists a freshly created entry FIRST, so its `capwip-victim` fragment counts at n=1 — inside
# the budget — and the pre-fix basename code never reached the rm. Backdated, the fragment is counted
# after the budget, which is the only ordering in which the escape is reachable.
mkdir -p "$PN/wip/capwip-a
capwip-victim"
touch -t 200001010000 "$PN/wip/capwip-a
capwip-victim"
mkdir -p "$PN/cwd/capwip-victim"
last_line="$(ls -1dt "$PN/wip"/capwip-* 2>/dev/null | tail -1)"
case "$last_line" in capwip-victim) rc=0 ;; *) rc=1 ;; esac
ck "FIXTURE: the newline entry sorts LAST, so its fragment is counted after the keep budget (else this arm is vacuous)" $rc
( cd "$PN/cwd" && bash -c '. "$1"; WIP_SNAPSHOT_KEEP=10; cap_wip_prune "$2"' _ "$GATE" "$PN/wip" )
[ -d "$PN/cwd/capwip-victim" ]; rc=$?
ck "a NEWLINE in a capwip name cannot make the retention rm -rf escape the wip root (victim survives)" $rc
pkept=0
for d in "$PN/wip"/capwip-*/; do [ -d "$d" ] && pkept=$((pkept + 1)); done
[ "$pkept" -ge 10 ]; rc=$?
ck "…and the ordinary snapshots are still retained (kept=$pkept of 12 + the newline-named one)" $rc

# ⛔ AND THE REPLAY LINE MUST NOT PASTE A `git apply` OF AN EMPTY PATCH (review finding, P3). An
# untracked-only tree produces a 0-byte tracked.patch, and `git apply` on it exits 128 ("No valid
# patches in input") — an instruction that fails at the moment somebody is rescuing work, mirroring the
# tarball that was never created (cycle 12).
UO="$CAPRIG/untrackedonly"; rm -rf "$UO"; git init -q -b main "$UO"
printf 'base\n' > "$UO/f.txt"; git -C "$UO" add f.txt
git -C "$UO" -c user.email=t@t -c user.name=t commit -q -m base
printf 'only untracked\n' > "$UO/only-untracked.txt"
: > "$FB/log19"
fb="$(PATH="$CAPRIG/bin:$PATH" O="$CO" WIP_PATH="$UO" bash -c '
  . "$1"
  cap_wip_snapshot "untracked only" 5 5 143 "$2" >/dev/null 2>&1
  printf "rc=%s result=%s dir=%s" "$?" "$WIP_SNAPSHOT_RESULT" "${WIP_SNAPSHOT_DIR:-none}"
' _ "$GATE" "$FB/log19")"
grep -q 'no tracked changes were captured' "$FB/log19"; rc=$?
ck "an UNTRACKED-ONLY tree says there is no patch to apply, instead of pasting a git-apply of 0 bytes ($fb)" $rc
# ⛔ MATCH THE COMMAND, NOT THE WORD (verification finding): the honest wording contains "patch to
# apply", so `/apply/` matched its own prose and the arm failed on a correct fix. `git -C` is the
# invocation shape — that is what must be absent when there is no patch.
ue="$(awk '/replay:/ && /git -C/ {n++} END{print n+0}' "$FB/log19")"
[ "$ue" -eq 0 ]; rc=$?
ck "…and its replay line contains no git-apply invocation at all" $rc

# ⛔ AND THE LAUNCHER MUST REPORT IT (#2045 indicator (b)). `nonblocking-dispatch.sh --status` used to
# answer a cap kill with a bare exit status — and `worker finished: commits=0` in the reported line —
# so a supervisor reading it saw a healthy quiescent lane and did NOT re-dispatch. Driven end to end:
# a real dispatch, a worker killed at a 1 s cap, and the status line read back.
BG="$CAPRIG/bg"; mkdir -p "$BG/logs" "$BG/state"
cap_clean; cap_dirty
# ⛔ THIS FIXTURE IS GATED TOO (review cycle 4, P1). `nonblocking-dispatch.sh` runs the research-first
# gate in the FOREGROUND, so a bare `a prompt` brief is refused with 80 and NO worker is ever started —
# the three cap-kill arms below then read "lost (no exit status recorded)" and assert a cap kill on a
# dispatch that never happened. MEASURED: 165 passed / 3 failed, and the same rc/status string reproduced
# standalone. Rendered from the validator with the role the dispatcher gates on (`worker`, i.e. KIND=bg),
# and asserted at BUILD time: a fixture that drifts must fail here, by name, not three arms later as a
# mysterious "lost" lane.
{ printf 'a prompt for a background worker\n\n'; bash "$HERE/brief-gate.sh" --section worker; } > "$BG/prompt"
bash "$HERE/brief-gate.sh" --check "$BG/prompt" worker 2>/dev/null \
  || { echo "  ❌ the cap-kill fixture brief is REFUSED by the research-first gate" >&2; exit 1; }
pi() { sleep 30; }            # exported: a FUNCTION beats the launcher's own PATH prepend (#1828)
export -f pi
( cd "$CWT" && O="$BG" PATH="$CAPRIG/bin:$PATH" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 \
    bash "$HERE/nonblocking-dispatch.sh" caplane "$CWT" "$BG/prompt" 1 >"$BG/dispatch.out" 2>&1 )
n=0; while [ ! -s "$BG/bg/caplane.rc" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n+1)); done
st="$(O="$BG" bash "$HERE/nonblocking-dispatch.sh" --status caplane 2>&1)"
case "$st" in
  *"failed rc="*) stfail=0 ;;
  *"done rc=0"*)  stfail=1 ;;
  *)              stfail=1 ;;
esac
ck "nonblocking-dispatch --status reports a cap-killed lane as FAILED, never as finished ($st)" $stfail
grep -q 'cap 1s hit' <<<"$st"; rc=$?
ck "…and NAMES the cap and the preserved snapshot, so the loss is visible in the fleet's accounting" $rc
# ⛔ AND IT MUST NOT SOFTEN A FAILED SNAPSHOT (VGATE cycle 3, F2, end to end). Same dispatch, but the
# snapshot cannot be taken, so the status must say WORK NOT PRESERVED — never "nothing was lost".
# ⛔ THE ARM'S PREMISE IS CORRECTED FOR #2409, NOT THE ASSERTION. "A cap kill OUTSIDE a git worktree"
# is unreachable end to end on the merged tree: `run_agent` derives the repo from the SPAWN cwd, so a
# non-repo cwd is HELD by the creation back-pressure gate (74) before any worker starts — the arm then
# measured the BACKLOG gate and never the snapshot verdict (measured on the integration branch:
# `caplane2 failed rc=74`, no cap, no snapshot). The reachable shape of the same defect — and the one
# the shipped message itself names ("If this lane's work lives in another directory, pass
# WIP_PATH=<worktree>") — is a lane that spawns from a real worktree whose WIP_PATH points somewhere
# that is not one: the spawn is measured, the cap fires, and the snapshot cannot be taken. So the
# dispatch runs in an origin-bearing worktree and WIP_PATH names the non-git dir. Nothing is softened:
# the cap still fires, the snapshot still genuinely fails, and the status must still say so.
NWT="$CAPRIG/norepo-wt"; mkdir -p "$NWT"
git -C "$NWT" init -q -b main
git -C "$NWT" remote add origin https://github.com/owner/repo.git
git -C "$NWT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
pi() { sleep 30; }
export -f pi
( cd "$NWT" && O="$BG" WIP_PATH="$FB/notagit" PATH="$CAPRIG/bin:$PATH" DISK_MIN_FREE_MB=1 DISK_LANE_TREE_MB=0 DISK_LANE_RESERVE_MB=0 \
    bash "$HERE/nonblocking-dispatch.sh" caplane2 "$NWT" "$BG/prompt" 1 >"$BG/dispatch2.out" 2>&1 )
n=0; while [ ! -s "$BG/bg/caplane2.rc" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
st2="$(O="$BG" bash "$HERE/nonblocking-dispatch.sh" --status caplane2 2>&1)"
grep -q 'WORK NOT PRESERVED' <<<"$st2"; rc=$?
ck "…and a cap kill it could NOT snapshot reports WORK NOT PRESERVED ($st2)" $rc
case "$st2" in *"nothing was lost"*) nl=1 ;; *) nl=0 ;; esac
ck "…and that line never claims 'nothing was lost' over work only the worktree still holds" $nl
unset -f pi

# ── 13) a suite nothing RUNS is not a gate ──────────────────────────────
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
