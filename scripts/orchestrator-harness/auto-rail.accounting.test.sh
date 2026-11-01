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
#     the whole actuator; the loop line is therefore pinned by the assertion at “the loop's own call”
#     below. It catches `"$repo"` losing its `$REPOS`; it cannot catch a reordering inside the line.
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
eval "$(sed -n '/^max_total_for() {/,/^}$/p' "$SUT")"
for _fn in rails_for_repo rails_should_defer candidate_deferred rail_already_running max_total_for; do
  command -v "$_fn" >/dev/null || { echo "FATAL: $_fn not found in $SUT"; exit 2; }
done
# ⛔ `rails_should_defer` calls `say`, which the SCRIPT defines and this file does not — so without a stub
# the fail-closed diagnostic resolves to /usr/bin/say (macOS text-to-speech) and is SPOKEN instead of
# printed, a silent dependency on an unrelated system binary (measured, round 5).
say() { printf '%s\n' "$*" >&2; }

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
# usable. Two shapes: no output at all, and a SHORT parse ("0 0") whose fields concatenate to "00".
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