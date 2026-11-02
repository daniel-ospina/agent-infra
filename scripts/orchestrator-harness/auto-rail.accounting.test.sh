#!/bin/bash
# Pin the merge-slot accounting of auto-rail.sh. What is under test is EXTRACTED FROM THE SCRIPT ITSELF,
# never restated here: the counter, the defer predicate, the call site's shape and the aggregate's
# derivation. A copy of the rule in this file (e.g. a literal `MAX_TOTAL=16`, or an `if [ total -ge MAX ]`
# standing in for the call site) pins nothing: the shipped line could then be broken or disarmed with the
# suite still green.
#
# ⛔ WHAT EACH PIN CAN AND CANNOT SEE — stated, because a test that overclaims is a false record:
#   * DRIVEN (behaviour): `rails_for_repo`, `rails_should_defer`, `candidate_deferred`'s shape and
#     `max_total_for`. Mutating any of them reddens this suite — measured, see the mutation list in the
#     commit that added them.
#   * GREPPED (text, and declared as text): the pass LOOP's invocation of `candidate_deferred`. The loop
#     runs `while :` around a live `gh`/`ps`/supervisor pass, so driving it here would mean stub-driving
#     the whole actuator; the loop line is therefore pinned by the assertion at "the loop's own call"
#     below. It compares the WHOLE captured argument string against the exact literal, so a reordering
#     inside the line is caught too; what it cannot see is the line becoming UNREACHABLE (moved below a
#     `continue`, or wrapped in `if false`) — that class is not pinned by anything here, and saying so
#     is the point of this paragraph. What the loop DECIDES is pinned by behaviour: `rail_already_running`
#     (three answers), `rail_says_skip` (rc -> action) and the MAX/MAX_TOTAL validation are all driven.
#   * NOT PINNED AT ALL, declared rather than left to be discovered: the loop's HEAD-READ guard and the
#     `echo … >> "$TRIED"` cooldown write (a `gh pr view` failure must skip the candidate, not write a
#     cooldown key with an empty head), and the startup precondition refusals (cooldown ledger, rail-verdict
#     directory). All are loop/startup lines, `TRIED`/`$RAIL_DIR` are not env-overridable seams, and driving
#     either means stub-driving the actuator. They are guarded in the SUT and unpinned here — verified by
#     reading, not by this suite. The two LOOP GUARD lines that CAN be pinned cheaply are pinned as text
#     (below with `candidate_deferred`): deleting the guard, or faking its input, is what cycle 4 measured.
#
# The fixture is `ps -eo args=` output from this box on 2026-11-01 at ~17:11Z, captured immediately
# BEFORE the actuator restart at 17:12:02Z cleared the population (the restart is the collateral
# recorded in agent-infra#3224; `rails_live` reads 0 at 17:12:08Z and that is the same table, emptied).
# It is 8 rows: 7 on agent-infra — six carrying `--repo daniel-ospina/agent-infra`, one of them the
# duplicate launch of #3136, PLUS another lane's worktree dry-run attributed by its script path — and 1
# on tortoise.
set -u
HERE=$(dirname "$0")   # the SCRIPT under test: the tracked copy beside this file
SUT=${AUTO_RAIL_SCRIPT:-$HERE/auto-rail.sh}
MAX=${MAX:-8}

# ── the shipped functions, extracted (the multi-line one runs to the first column-0 `}`) ──────────────
eval "$(sed -n '/^rails_for_repo() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rails_should_defer() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^candidate_deferred() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rail_already_running() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rail_says_skip() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^max_total_for() {/,/^}$/p' "$SUT")"
for _fn in rails_for_repo rails_should_defer candidate_deferred rail_already_running rail_says_skip max_total_for; do
  command -v "$_fn" >/dev/null || { echo "FATAL: $_fn not found in $SUT"; exit 2; }
done
# ⛔ `rails_should_defer` calls `log_line`, which the SCRIPT defines and this file does not — so without a
# stub the fail-closed diagnostic resolves to a name this file never defined. The stub is NOT cosmetic:
# the helper was called `say` until #2910's prohibition (tests/no-tts/run.sh refuses that NAME in every
# shipped script, because on macOS it is /usr/bin/say and the diagnostic is SPOKEN instead of printed),
# and the same hazard applies to whatever the helper is called next. Measured round 5: without the stub
# the message went to a system binary; measured 2026-11-02: with `say` still defined here, this suite's
# own file was named by no-tts as an offender.
log_line() { printf '%s\n' "$*" >&2; }

REPOS="daniel-ospina/tortoise daniel-ospina/agent-infra"
TABLE="$(cat <<'ROWS'
bash /Users/danielospina/Documents/GitHub/agent-infra/.worktrees/rail-exit-after-verdict/scripts/admin-merge.sh 42 --main-runs 10 --dry-run
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3054 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3055 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3057 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3212 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 10500 --repo daniel-ospina/tortoise
ROWS
)"
ps() { printf '%s\n' "$TABLE"; }

fail=0
read -r t_own t_total t_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
read -r a_own a_total a_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
printf 'captured table: tortoise=%s/%s/%s agent-infra=%s/%s/%s (own/total/unknown)\n' \
  "$t_own" "$t_total" "$t_unk" "$a_own" "$a_total" "$a_unk"

# The partition: every rail lands on exactly one repo or the unknown bucket.
[ "$t_total" -eq 8 ] || { echo "FAIL: total $t_total != 8"; fail=1; }
[ "$t_unk" -eq 0 ]   || { echo "FAIL: unknown $t_unk != 0 (each row names its repo in --repo or in its path)"; fail=1; }
[ "$t_own" -eq 1 ]   || { echo "FAIL: tortoise own $t_own != 1"; fail=1; }
[ "$a_own" -eq 7 ]   || { echo "FAIL: agent-infra own $a_own != 7 (6 via --repo incl. the #3136 duplicate, + the worktree dry-run by path)"; fail=1; }
[ $(( t_own + a_own + t_unk )) -eq "$t_total" ] || { echo "FAIL: the three buckets do not partition the table"; fail=1; }

# ⛔ THE DEFECT AS A DECISION, through the SHIPPED PREDICATE. On this table main's rule
# (`total >= MAX`) defers tortoise; the shipped rule must not. The old rule is spelled out here ONLY as
# the contrast the fix is measured against — it is not a stand-in for the call site (that is driven
# below, at `candidate_deferred`).
MAX_TOTAL=16 MAX=8
if [ "$t_total" -ge 8 ]; then echo "old rule (total>=MAX) for a tortoise candidate: DEFER"; else echo "FAIL: fixture no longer reproduces the defect"; fail=1; fi
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "FAIL: new rule DEFERS tortoise on this table"; fail=1
else echo "new rule (per repo) for a tortoise candidate: LAUNCH"; fi

# ⛔ THE CALL SITE, DRIVEN — the wrapper's SHAPE, and the argument-mangling class (dropping the
# population inside it, or forwarding it wrongly) reddens here. 8 rails on the OTHER repo must not shut
# tortoise's queue, and the same table with the population dropped must DEFER, which is what proves the
# population argument is load-bearing rather than decorative. The LOOP's invocation is pinned separately
# below — this block cannot see it.
MAX_TOTAL=16 MAX=8
TABLE="$(for i in 1 2 3 4 5 6 7 8; do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/agent-infra"; done)"
candidate_deferred daniel-ospina/tortoise $REPOS && { echo "FAIL: 8 rails on the OTHER repo deferred tortoise's candidate — that is the starvation this PR fixes"; fail=1; }
candidate_deferred daniel-ospina/tortoise || { echo "FAIL: with the population dropped these rails must read as UNKNOWN and defer — if they do not, this assertion no longer proves the argument is load-bearing"; fail=1; }

# ⛔ THE LOOP'S OWN CALL — a TEXT assertion, and labelled as one on purpose. Mutating the loop from
# `candidate_deferred "$repo" $REPOS` to `candidate_deferred "$repo"` restores the starvation exactly
# (measured: every other repo's rails become UNKNOWN and defer, see the assertion above) and this block
# is the only thing that reddens for it. It is a grep, not a drive, because the loop cannot run here
# without stub-driving the actuator; it is honest about that in the header rather than claiming the
# wrapper's drive covers it.
loop_call=$(sed -n 's/^[[:space:]]*if candidate_deferred \(.*\); then$/\1/p' "$SUT")
[ "$loop_call" = '"$repo" $REPOS' ] \
  || { echo "FAIL: the loop must invoke candidate_deferred as \"\$repo\" \$REPOS (got '$loop_call') — dropping \$REPOS turns every other repo's rails into UNKNOWN load and re-creates the starvation with the predicate untouched"; fail=1; }

# ⛔ THE DUPLICATE-RAIL GUARD AT ITS ONLY CALL SITE — also text, also declared. Cycle 4 measured two ways
# to undo it with the suite green: fake the guard's input (`_rail_rc=1`) and delete the skip block. The
# functions are DRIVEN above; what is pinned here is that the loop still ASKS them and still acts on the
# answer. Both compares are whole-line literals, so an edit inside either line reddens.
guard_call=$(sed -n 's/^[[:space:]]*rail_already_running "\(.*\)"; _rail_rc=\$?$/\1/p' "$SUT")
[ "$guard_call" = '$pr' ] \
  || { echo "FAIL: the loop must ASK rail_already_running about the candidate (got 'rail_already_running \"$guard_call\"') — a guard the loop never calls cannot stop a duplicate rail"; fail=1; }
skip_call=$(sed -n 's/^[[:space:]]*if rail_says_skip "\(.*\)"; then$/\1/p' "$SUT")
[ "$skip_call" = '$_rail_rc' ] \
  || { echo "FAIL: the loop must ACT on the guard's answer via rail_says_skip (got '$skip_call') — deleting this turns 'cannot tell' back into a launch"; fail=1; }

# …and the bound still BITES, in both clauses.
TABLE="$(for i in 1 2 3 4 5 6 7 8; do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/tortoise"; done)"
MAX_TOTAL=16 MAX=8
rails_should_defer daniel-ospina/tortoise $REPOS || { echo "FAIL: 8 rails on ONE repo must defer a 9th candidate there"; fail=1; }
TABLE="$(for i in $(seq 1 16); do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/agent-infra"; done)"
MAX_TOTAL=16 MAX=8
rails_should_defer daniel-ospina/tortoise $REPOS || { echo "FAIL: the MAX_TOTAL clause must bite at 16 live"; fail=1; }

# Fail-closed: unknown load counts for EVERY repo, never for none.
TABLE="$(for i in $(seq 1 8); do echo "bash /opt/other/scripts/admin-merge.sh $i --repo some-org/third-repo"; done)"
MAX_TOTAL=16 MAX=8
read -r u_own u_total u_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
[ "$u_own" -eq 0 ] && [ "$u_unk" -eq 8 ] || { echo "FAIL: a --repo naming an undriven repo must be unknown (own=$u_own unk=$u_unk)"; fail=1; }
rails_should_defer daniel-ospina/tortoise $REPOS || { echo "FAIL: 8 unattributable rails must count against every repo's MAX"; fail=1; }

# Precedence: `--repo` decides, so one rail is never counted on two repos.
TABLE="bash /Users/x/agent-infra/.worktrees/y/scripts/admin-merge.sh 42 --repo daniel-ospina/tortoise"
read -r p_t_own p_t_total _p <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
read -r p_a_own _p2 _p3 <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$p_t_own" -eq 1 ] && [ "$p_a_own" -eq 0 ] \
  || { echo "FAIL: --repo must take precedence over the script path (tortoise=$p_t_own agent-infra=$p_a_own)"; fail=1; }

# ⛔ THE DUPLICATE-RAIL GUARD HAS THREE ANSWERS, and "cannot tell" is not "none". The fixture's own
# rows include TWO live rails for #3136 (the duplicate launch recorded in the file header) — the exact
# state in which a guard that read an unreadable table as "no rail" would have launched a third.
TABLE="bash /r/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra
bash /r/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra"
rail_already_running 3136; [ $? -eq 0 ] || { echo "FAIL: a live rail for #3136 must be DETECTED (rc 0)"; fail=1; }
rail_already_running 9999; [ $? -eq 1 ] || { echo "FAIL: with no rail for #9999 the guard must answer rc 1 (not running), not a refusal"; fail=1; }

# ⛔ THE PR NUMBER IS NOT ALWAYS FOLLOWED BY AN ARGUMENT. `admin-merge.sh <PR>` — the form this repo's
# own merge path tells operators to use — puts it LAST, and the old `grep "admin-merge.sh $1 "` needed a
# trailing space, so it answered rc 1 ("no rail") for a rail that was live, and the actuator launched a
# second one. `merge-reminder.py` reads the same table and matches the PR as ANY argv token for exactly
# this reason ("a hand-started rail is still a rail").
for _shape in "bash /r/hub/scripts/admin-merge.sh 3136" \
              "bash /r/hub/scripts/admin-merge.sh 3136 --any-workflow" \
              "bash /r/hub/scripts/admin-merge.sh --repo daniel-ospina/agent-infra 3136"; do
  TABLE="$_shape"
  rail_already_running 3136 || { echo "FAIL: this is a live rail for #3136 and the guard must DETECT it: $_shape"; fail=1; }
done
for _shape in "bash /r/hub/scripts/admin-merge.sh 13136" \
              "bash /r/hub/scripts/admin-merge.sh 31360 --repo daniel-ospina/agent-infra" \
              "bash /r/hub/scripts/admin-merge.sh 9999 --repo daniel-ospina/agent-infra"; do
  TABLE="$_shape"
  rail_already_running 3136 && { echo "FAIL: the PR token must be boundary-matched — #3136 is NOT running here: $_shape"; fail=1; }
done

# ⛔ THE PASS'S ACTION, DRIVEN FROM THE GUARD'S CONTRACT. 0 = a rail is live, 1 = none, 2 = CANNOT TELL.
# Collapsing "cannot tell" into "none" is the fail-open cycle 2 fixed, and the mapping is one line at
# the loop — so it is pinned by BEHAVIOUR here, not by a grep at the call site.
rail_says_skip 0   || { echo "FAIL: rc 0 (a rail is live) must SKIP the candidate"; fail=1; }
rail_says_skip 2   || { echo "FAIL: rc 2 (CANNOT TELL) must SKIP the candidate, never launch"; fail=1; }
rail_says_skip 255 || { echo "FAIL: an unexpected rc must SKIP the candidate, never launch"; fail=1; }
rail_says_skip 1   && { echo "FAIL: rc 1 (no rail) must PROCEED — refusing here would stall the queue"; fail=1; }

# ⛔ NON-POSITIVE BOUNDS ARE REFUSED — driven from a copy whose LOG PATH IS PRIVATE, so the assertion can
# read the guard's own `REFUSED: …` line. `rc=3` alone is NOT discriminating: the script exits 3 for a
# missing rail too, so a deleted guard would still "pass" (measured — this assertion was a false pass
# until the log was matched). `MAX=0 MAX_TOTAL=16` is the discriminating env: with the aggregate positive,
# only the MAX guard can refuse it.
_sutlog=$(mktemp); _sut0=$(mktemp)
sed "s#/tmp/auto-rail.log#$_sutlog#g" "$SUT" > "$_sut0"
# _check_refusal <env> <line prefix> <reason fragment> — three assertions, because each alone can pass for
# the wrong reason: rc=3 is also a missing rail, the prefix does not prove the reason survived, and the
# reason without the prefix could come from the other bound's guard.
_check_refusal() {
  local rc
  : > "$_sutlog"
  env $1 bash "$_sut0" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || { echo "FAIL: $1 must be REFUSED (exit 3), got rc=$rc — a zero bound defers every candidate for ever"; fail=1; }
  # -F, not -q: the reason fragment contains a BRACKETED expression, which BRE reads as a character class
  # (`[ total -ge 0 ]` would match any of t,o,a,l,space,... and quietly match the wrong text).
  grep -qF "$2" "$_sutlog" || { echo "FAIL: $1 must log '$2' — a bare rc=3 is also what a missing rail produces, so the line is what proves the GUARD fired"; fail=1; }
  grep -qF "$3" "$_sutlog" || { echo "FAIL: $1 must log the REASON ('$3') — a message truncated by command substitution explains nothing"; fail=1; }
}
# `MAX=0 MAX_TOTAL=16` is the DISCRIMINATING pair: with the aggregate positive, only the MAX guard can
# refuse it — otherwise the MAX_TOTAL zero-check masks a deleted MAX check (measured: this passed for the
# wrong reason before the discriminating case and the reason-fragment assertion were added).
# The REASON fragments deliberately SPAN the bracketed expression: a fragment that survives its deletion
# ("true for every population") does not detect the command-substitution defect — measured, this assertion
# stayed green with backticks restored until the fragment included the clause itself.
_check_refusal "MAX=0"               "REFUSED: MAX="       "0 would defer every candidate for ever"
_check_refusal "MAX=0 MAX_TOTAL=16"  "REFUSED: MAX="       "0 would defer every candidate for ever"
_check_refusal "MAX_TOTAL=0"         "REFUSED: MAX_TOTAL=" "aggregate clause '[ total -ge 0 ]' true"
_check_refusal "MAX=8 MAX_TOTAL=0"   "REFUSED: MAX_TOTAL=" "aggregate clause '[ total -ge 0 ]' true"

# ⛔ THE RAIL-VERDICT DIRECTORY IS A PRECONDITION TOO — and its absence used to be invisible: a launch whose
# redirect cannot be opened returns 0 to the caller, so the log said `launching rail` for a rail that never
# started, and the cooldown then reported "already railed … only a NEW HEAD can change" over it (measured
# cycle 4). Driven from a copy whose RAIL_DIR cannot be created, so the refusal is the SHIPPED one.
_sutdir=$(mktemp); _thumb=$(mktemp -d)
# A throwaway rail hub: the gh-shim check runs BEFORE the RAIL_DIR check, so the refusal under test can only
# be reached with a hub whose shim and rail script exist. `RAIL_SCRIPT=/bin/true` would fail the shim check
# first and this assertion would pass for the wrong reason (measured — it did, on the first attempt).
mkdir -p "$_thumb/hub/scripts/gh-shim"
: > "$_thumb/hub/scripts/gh-shim/gh"; chmod +x "$_thumb/hub/scripts/gh-shim/gh"
: > "$_thumb/hub/scripts/admin-merge.sh"
sed -e "s#/tmp/auto-rail.log#$_sutlog#g" -e 's#^RAIL_DIR=.*#RAIL_DIR=/proc/no/such/rail-dir#' "$SUT" > "$_sutdir"
: > "$_sutlog"
env MAX=8 RAIL_SCRIPT="$_thumb/hub/scripts/admin-merge.sh" bash "$_sutdir" >/dev/null 2>&1; _drc=$?
[ "$_drc" -eq 3 ] || { echo "FAIL: an uncreatable rail-verdict directory must be REFUSED (exit 3), got rc=$_drc — otherwise every launch fails silently and is recorded as railed"; fail=1; }
grep -q "REFUSED: cannot create a writable rail-verdict directory" "$_sutlog" \
  || { echo "FAIL: the rail-verdict refusal must name itself in the log — a silent per-launch failure is the defect (log: $(cat "$_sutlog"))"; fail=1; }
rm -rf "$_sutdir" "$_thumb"
rm -f "$_sutlog" "$_sut0"

# ⛔ THE AGGREGATE'S DERIVATION IS PINNED BY EVALUATING THE SHIPPED LINE, not by a literal in this file.
# `MAX_TOTAL=16` used to appear here as a constant, so `MAX_TOTAL=${MAX_TOTAL:-$(max_total_for …)}` could
# be replaced by `MAX * 1`, `MAX * 1000` or a flat `16` with this suite still green — and the aggregate is
# the ONLY thing stopping per-repo budgets from silently multiplying the load bound.
MAX=8
MAX_TOTAL=
eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"
[ "$MAX_TOTAL" = 16 ] || { echo "FAIL: MAX_TOTAL must derive from MAX x the repos driven (2 repos x MAX=8 => 16), got '$MAX_TOTAL'"; fail=1; }
( REPOS="a/one b/two c/three"; MAX_TOTAL=; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 24 ] ) \
  || { echo "FAIL: a THIRD driven repo must widen the aggregate to 24 — a derivation that ignores REPOS lets per-repo budgets multiply the bound"; fail=1; }
( REPOS="a/one"; MAX_TOTAL=; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 8 ] ) \
  || { echo "FAIL: ONE driven repo must give MAX_TOTAL=8, i.e. the bound scales with REPOS and is not a constant"; fail=1; }
# …and an explicit override still wins, so an operator can tune it.
( MAX_TOTAL=5; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 5 ] ) \
  || { echo "FAIL: an explicit MAX_TOTAL must not be overwritten by the derivation"; fail=1; }

# ⛔ A FAILED DATA SOURCE IS NOT AN EMPTY QUEUE — the counter path's own fail-open, pinned. This script
# has no `pipefail`, so a `ps` that cannot run left python reading EOF and printing a parseable `0 0 0`:
# every bound disarmed, and the pass logged exactly what a healthy idle box logs. An EMPTY table is a
# legitimate `0 0 0` (asserted further down); an UNREADABLE one must defer.
ps() { return 1; }
MAX_TOTAL=16 MAX=8
rail_already_running 3136; [ $? -eq 2 ] || { echo "FAIL: an unreadable process table must answer rc 2 (CANNOT TELL), never rc 1 (none) — rc 1 is what launches a second rail for a PR that already has one"; fail=1; }
if candidate_deferred daniel-ospina/tortoise $REPOS; then echo "fail-closed on an unreadable process table (ps rc!=0): DEFER (correct)"
else echo "FAIL: a ps that could not run read as an EMPTY population and LAUNCHED — that is the fail-open this asserts against"; fail=1; fi

# ⛔ AN UNREADABLE COUNTER MUST DEFER (fail-closed) — and this case PINS it: without it the guard can be
# deleted and the whole test still prints PASS. The stub overrides `rails_for_repo` (not `ps`) because an
# EMPTY PROCESS TABLE legitimately yields `0 0 0`; what must fail closed is a counter that prints nothing
# usable. Two shapes: no output at all, and a SHORT parse ("0 0") that leaves the THIRD field EMPTY —
# `read` gives `own=0 total=0 unk=''`, so the string is `:0:0::` and the `*::` alternative catches it.
# Nothing concatenates anything (an earlier version of this comment claimed the fields "concatenate to
# 00", which is not the mechanism and invites a "simplification" of a guard that does work).
rails_for_repo() { printf '%s' "$RAILS_OUT"; }
MAX_TOTAL=16 MAX=8
RAILS_OUT=""
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "fail-closed on an empty counter: DEFER (correct)"
else echo "FAIL: an empty counter must DEFER, not launch"; fail=1; fi
RAILS_OUT="0 0"
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "fail-closed on a short parse: DEFER (correct)"
else echo "FAIL: a short parse ('0 0') must DEFER, not read as free load"; fail=1; fi
RAILS_OUT="0 0 0"
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "FAIL: a genuinely empty population must not defer"; fail=1
else echo "a genuinely empty population: LAUNCH (correct)"; fi

[ "$fail" = 0 ] && echo "PASS: per-repo accounting launches a starved repo's candidate, still bounds one repo, and counts unknown load against everyone"
exit "$fail"