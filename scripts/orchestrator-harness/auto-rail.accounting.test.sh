#!/bin/bash
# Decide the deferral the way the DEPLOYED auto-rail.sh decides it, over a REAL captured process
# table. The table below is verbatim `ps -eo args=` output captured on this box at 2026-11-01T17:12Z
# (8 rows: 6 rails on agent-infra, one of them a duplicate launch; 1 on tortoise; 1 launched by another
# lane out of a worktree, which passed no --repo and is attributed by its script path).
set -u
HERE=$(dirname "$0")   # the SCRIPT under test: the tracked copy beside this file
DEPLOYED=${AUTO_RAIL_SCRIPT:-$HERE/auto-rail.sh}
MAX=8
MAX_TOTAL=16

# ── the three accounting functions, EXTRACTED FROM THE DEPLOYED SCRIPT (so this tests the shipped code) ──
eval "$(grep -E '^rails_(live_total|on|unknown)\(\) ' "$DEPLOYED")"

ps() { printf '%s\n' "$TABLE"; }
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

total=$(rails_live_total)
tortoise=$(rails_on tortoise)
ai=$(rails_on agent-infra)
unattributed=$(rails_unknown tortoise agent-infra)

printf 'captured table: total=%s tortoise_on_repo=%s agent-infra_on_repo=%s unattributed=%s\n' \
  "$total" "$tortoise" "$ai" "$unattributed"

fail=0
# The attribution itself: every rail lands on exactly one repo (or the unknown bucket), and the
# unknown bucket is EMPTY for this table because each row names its repo in --repo or in its path.
[ "$total" -eq 8 ]        || { echo "FAIL: total rails $total != 8"; fail=1; }
[ "$ai" -eq 7 ]           || { echo "FAIL: agent-infra attribution $ai != 7 (the #3136 duplicate + the worktree dry-run both belong to it)"; fail=1; }
[ "$tortoise" -eq 1 ]     || { echo "FAIL: tortoise attribution $tortoise != 1"; fail=1; }
[ "$unattributed" -eq 0 ] || { echo "FAIL: unattributed $unattributed != 0"; fail=1; }

# ⛔ THE DEFECT, AS A DECISION. On this exact table:
#   OLD (global):   running_declared = $total = 8 >= MAX 8  -> tortoise DEFERRED
#   NEW (per repo): tortoise own = 1 < MAX 8, total 8 < MAX_TOTAL 16 -> everything below the bar
# The old verdict is what /tmp/auto-rail.log recorded at 16:48Z ("deferred (11 rails already live,
# max=8)") while tortoise contributed one of those rails.
old_defer=0; [ "$total" -ge "$MAX" ] && old_defer=1
new_defer=0; { [ "$tortoise" -ge "$MAX" ] || [ "$total" -ge "$MAX_TOTAL" ]; } && new_defer=1
printf 'OLD decision for a tortoise candidate: %s\n' "$([ "$old_defer" = 1 ] && echo DEFER || echo LAUNCH)"
printf 'NEW decision for a tortoise candidate: %s\n' "$([ "$new_defer" = 1 ] && echo DEFER || echo LAUNCH)"
[ "$old_defer" = 1 ] || { echo "FAIL: the old rule should DEFER on this table (that is the defect being fixed)"; fail=1; }
[ "$new_defer" = 0 ] || { echo "FAIL: the new rule must LAUNCH on this table"; fail=1; }

# The bound still BITES when it should: 8 rails on THIS repo defers a 9th candidate here.
TABLE="$(for i in $(seq 1 8); do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/tortoise"; done)"
[ "$(rails_on tortoise)" -ge "$MAX" ] || { echo "FAIL: 8 rails on one repo must still hit the per-repo bound"; fail=1; }
# Fail-closed: a rail nobody can attribute counts for EVERY repo, never for none.
TABLE="bash /somewhere/else/admin-merge.sh 7"
[ "$(rails_unknown tortoise agent-infra)" -eq 1 ] \
  || { echo "FAIL: an unattributable rail must be counted as unknown"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: per-repo accounting launches a starved repo's candidate and still bounds one repo"
exit "$fail"
