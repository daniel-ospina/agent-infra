#!/bin/bash
# Pin the merge-slot accounting of auto-rail.sh. The functions under test are EXTRACTED FROM THE SCRIPT
# ITSELF — including the defer predicate, so reverting the fix fails this test instead of passing it.
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
command -v rails_should_defer >/dev/null || { echo "FATAL: rails_should_defer not found in $SUT"; exit 2; }

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

# ⛔ THE DEFECT AS A DECISION, through the SHIPPED predicate. On this table main's rule
# (`total >= MAX`) defers tortoise; the shipped rule must not.
MAX_TOTAL=16 MAX=8
if [ "$t_total" -ge 8 ]; then echo "old rule (total>=MAX) for a tortoise candidate: DEFER"; else echo "FAIL: fixture no longer reproduces the defect"; fail=1; fi
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "FAIL: new rule DEFERS tortoise on this table"; fail=1
else echo "new rule (per repo) for a tortoise candidate: LAUNCH"; fi

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
