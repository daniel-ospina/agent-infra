#!/bin/bash
# adopt-fix.sh <repo> <owner/repo> <pr> <branch>
# For a PR on an EXTERNAL (other-machine) branch: ensure a local worktree exists, then run the fix chain.
set -u
REPO="$1"; OR="$2"; PR="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
mkdir -p "$O/logs"
cd "$REPO" || exit 1
git fetch origin "$BR" --quiet 2>/dev/null || true
WT=".worktrees/adopt-$PR"
# Capture, then classify in the SHELL — never `… | grep -q`, whose false negative under
# `pipefail` would re-run `worktree add` over an existing worktree and abort (#864).
wt_registered=0
case "$(git worktree list 2>/dev/null || true)" in *"/$WT "*) wt_registered=1 ;; esac
if [ "$wt_registered" -eq 0 ]; then
  git worktree add "$WT" "$BR" >/dev/null 2>&1 || { echo "[adopt-fix $PR] worktree add failed for $BR" | tee -a "$O/logs/adopt-$PR.log"; exit 1; }
fi
echo "[adopt-fix $PR] worktree=$WT branch=$BR $(date)" >> "$O/logs/adopt-$PR.log"
bash "$O/fix-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$O/logs/adopt-$PR.log" 2>&1
rc=$?
# 75 = the load gate refused to start the fixer (nothing ran, nothing consumed). 77 = the DISK gate
# refused it (#1765). Name BOTH here: the fixer's own line is inside fix-$PR.log, and this is the log
# a manual operator reads (#1720). They are not interchangeable — a load refusal is cleared by the
# box quietening, a disk refusal only by reclaiming space — so reporting one as the other sends the
# operator to wait for a remedy that cannot arrive.
if [ "$rc" = "75" ]; then
  echo "[adopt-fix $PR] fixer NOT started (load gate) — re-run when 1-min load is below MAX_LOAD" >> "$O/logs/adopt-$PR.log"
elif [ "$rc" = "77" ]; then
  echo "[adopt-fix $PR] fixer NOT started (DISK gate) — the filesystem is below DISK_MIN_FREE_MB. Reclaim space (cloud-cell-supervisor.sh prune); waiting will NOT clear it." >> "$O/logs/adopt-$PR.log"
# ⛔ AND THE CI-QUEUE GATE IS THE THIRD REFUSAL, NAMED IN THE LOG THE OPERATOR READS (#2333 cycle 6
# review, P2). `fix-one.sh` exits 0 here ON PURPOSE — a deferral is not an error the controller should
# retry, and the controller books the refund through the bail marker — so `adopt-fix <PR>` returned
# SUCCESS with nothing pushed, and the only line saying why sat in `fix-$PR.log`, which is NOT the log
# a manual operator reads (#1720). Nothing in the controller reads this script's status.
# ⛔ The code is 79, NOT 76: 76 is `PI_GATE_REFUSED` (spawn-gate.sh:318) — the SPAWN POINT's load
# refusal, which callers translate to 75. Reusing it here would make an operator who applies the
# repo's documented 76 mapping wait for load to fall, which never clears a CI queue — the exact
# wrong-cause class this block exists to fix (#2333 review). 79 is unassigned in scripts/.
elif [ "$rc" = "0" ] && grep -q 'DEFERRED by the CI-queue gate' "$O/logs/fix-$PR.log" 2>/dev/null; then
  echo "[adopt-fix $PR] fixer NOT started (CI-QUEUE gate) — the CI queue is deeper than the runners can drain, so nothing was pushed and no attempt was consumed; the depth is in $O/logs/fix-$PR.log. Re-run when it drains." >> "$O/logs/adopt-$PR.log"
  exit 79
fi
# ⛔ Exit with the FIXER's status, EXPLICITLY. `origin/main` ended on `bash "$O/fix-one.sh"`, so
# `$?` was already the fixer's. The reporting block ABOVE was added by this change, and an `if` with
# a false condition and no `else` returns 0 — measured: `if [ "$rc" = "75" ]; then echo x; fi`
# returns 0 for BOTH `rc=0` and `rc=75`. So the reporting line, made the last command, would have
# reported the load refusal it exists to NAME as a SUCCESS: a wrapper doing `adopt-fix.sh … && next`
# then takes the wrong branch and the exit code says the opposite of the log (#1720 review).
# `exit "$rc"` restores the contract rather than relying on the last command's status.
exit "$rc"
