#!/bin/bash
# adopt-fix.sh <repo> <owner/repo> <pr> <branch>
# For a PR on an EXTERNAL (other-machine) branch: ensure a local worktree exists, then run the fix chain.
set -u
REPO="$1"; OR="$2"; PR="$3"; BR="$4"
O="${O:-$HOME/orchestrator}"
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
mkdir -p "$O/logs"
cd "$REPO" || exit 1
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# ⛔ THE FOURTH CALLER OF THE GATED FIXER (#2762 review, P1/P2). This script built a worktree and
# fetched a branch BEFORE calling fix-one.sh, in whatever checkout `$1` named — so a mismatched pair
# did the wrong-repo work here, one layer above the assertion that was supposed to stop it, and then
# reported only an empty log. Assert the pair first; refuse before touching a branch.
. "$SELF/repo-target.sh" || { echo "[adopt-fix $PR] FATAL: $SELF/repo-target.sh missing (or its repo-slug.sh parser is) — refusing to adopt into a repo that cannot be asserted" >&2; exit 78; }
command -v repo_target_assert >/dev/null 2>&1 || { echo "[adopt-fix $PR] FATAL: $SELF/repo-target.sh is stale (no repo_target_assert) — refusing to adopt into a repo that cannot be asserted" >&2; exit 78; }
REPO_ABS="$(pwd -P)"
ADOPT_ASSERT_LINE="$(repo_target_assert "adopt-fix $PR" "$REPO_ABS" "$OR" "")"; ADOPT_ASSERT_RC=$?
printf '%s\n' "$ADOPT_ASSERT_LINE" >> "$O/logs/adopt-$PR.log"
if [ "$ADOPT_ASSERT_RC" -ne 0 ]; then
  echo "[adopt-fix $PR] fixer NOT started (REPO IDENTITY) — the checkout $REPO_ABS is not $OR; nothing fetched, no worktree built, no attempt consumed" >> "$O/logs/adopt-$PR.log"
  exit "$ADOPT_ASSERT_RC"
fi
# The worktree lifecycle helper (#2033): a failed `worktree add` here used to leave the branch — and
# for a foreign branch that is the ONE ref the adopt path just fetched, so the residue was durable.
# shellcheck source=/dev/null
. "$SELF/wt-lifecycle.sh" || { echo "[adopt-fix $PR] FATAL: $SELF/wt-lifecycle.sh missing — refusing to adopt without its rollback (#2033)" | tee -a "$O/logs/adopt-$PR.log"; exit 78; }
git fetch origin "$BR" --quiet 2>/dev/null || true
WT=".worktrees/adopt-$PR"
# `wt_provision` creates the worktree OR leaves nothing behind, ATTACHES the existing branch when it
# holds commits (the normal adopt case), and repairs a half-materialised/interrupted record instead of
# trusting it. It replaces the directory-name probe, which tested a NAME rather than a branch (#2033).
wt_provision "$REPO" "$WT" "$BR" "origin/$BR"
_wt_rc=$?
if [ "$_wt_rc" != 0 ]; then
  echo "[adopt-fix $PR] $WT_RESULT — cannot adopt $BR" | tee -a "$O/logs/adopt-$PR.log"
  exit 1
fi
echo "[adopt-fix $PR] worktree=$WT branch=$BR ($WT_RESULT) $(date)" >> "$O/logs/adopt-$PR.log"
bash "$O/fix-one.sh" "$REPO" "$OR" "$PR" "$BR" >> "$O/logs/adopt-$PR.log" 2>&1
rc=$?
# 75 = the load gate refused to start the fixer (nothing ran, nothing consumed). 77 = the DISK gate
# refused it (#1765). Name BOTH here: the fixer's own line is inside fix-$PR.log, and this is the log
# a manual operator reads (#1720). They are not interchangeable — a load refusal is cleared by the
# box quietening, a disk refusal only by reclaiming space — so reporting one as the other sends the
# operator to wait for a remedy that cannot arrive.
if [ "$rc" = "75" ]; then
  echo "[adopt-fix $PR] fixer NOT started (load gate) — re-run when 1-min load is below MAX_LOAD" >> "$O/logs/adopt-$PR.log"
elif [ "$rc" = "71" ]; then
  # ⛔ THE CAPABILITY REFUSAL (#2935) IS THE ONE THIS SCRIPT COULD NOT NAME AT ALL (review of #2991,
  # P1): `fix-one.sh` propagates the gate's own code, so 71 reached the manual operator's log as NO
  # LINE — a run that did nothing, silently. Waiting does not clear it, so it must not be folded into
  # the load arm above.
  echo "[adopt-fix $PR] fixer NOT started (CAPABILITY gate) — this box could not complete one model call and RETURN (#2935); see the [capability-gate] REFUSED line in $O/logs/fix-$PR.log for which reading refused. Waiting will not clear it: repair the box (installed pi/extension set, provider credential) or dispatch the PR elsewhere." >> "$O/logs/adopt-$PR.log"
elif [ "$rc" = "72" ]; then
  # A worktree that exists but is the wrong repo (or a branch the target repo does not have) is
  # refused by fix-one.sh with 72. Name it in the log the manual operator reads (#1720/#2694).
  echo "[adopt-fix $PR] fixer NOT started (REPO IDENTITY) — the worktree/branch is not $OR; nothing pushed, no attempt consumed. See $O/logs/fix-$PR.log." >> "$O/logs/adopt-$PR.log"
elif [ "$rc" = "77" ]; then
  # ⛔ CODE 77 IS TWO CONDITIONS (review round 1, P2): below the floor, and above it without the
  # headroom for one lane's tree (`DISK-NOHEADROOM`, agent-infra#2721). Naming only the floor told the
  # operator a full filesystem was the cause when it was not.
  echo "[adopt-fix $PR] fixer NOT started (DISK gate) — either the filesystem is below DISK_MIN_FREE_MB, or it has no headroom for one lane's dependency tree (DISK-NOHEADROOM). The '[disk-gate] REFUSED' line in the spawn log names which, with both terms. Reclaim space (cloud-cell-supervisor.sh prune --caches); waiting will NOT clear it." >> "$O/logs/adopt-$PR.log"
# ⛔ THE 79 DEFERRALS ARE NAMED IN THE LOG THE OPERATOR READS (#2333 cycle 6 review, P2).
# `fix-one.sh` exits 0 for each of them ON PURPOSE — a deferral is not an error the controller should
# retry, and the controller books the refund through the bail marker — so `adopt-fix <PR>` would return
# SUCCESS with nothing pushed, and the only line saying why sits in `fix-$PR.log`, which is NOT the log
# a manual operator reads (#1720). Nothing in the controller reads this script's status.
# ⛔ The code is 79, NOT 76: 76 is `PI_GATE_REFUSED` (spawn-gate.sh:318) — the SPAWN POINT's load
# refusal, which callers translate to 75. Reusing it here would make an operator who applies the
# repo's documented 76 mapping wait for load to fall while the real cause is a PR-owner LOCK, which no
# amount of waiting for the box to quieten will clear — the exact wrong-cause class this block exists
# to fix (#2333 review). 79 is unassigned in scripts/.
# ⛔ AND THERE IS NO CI-QUEUE ARM ANY MORE (#2927, and #2928's review): `fix-one.sh` no longer reads
# the CI queue, so it can never write `DEFERRED by the CI-queue gate`. The arm that used to sit here
# was UNREACHABLE — and worse than dead, because its message told a manual operator to "re-run when
# the queue drains" for a refusal that no longer exists, while a real deferral fell through to the
# `… && next` branch it was meant to stop. A reader that outlives its writer is the failure mode; the
# census that catches the next one is in `ci-queue.test.sh` (j4).
# ⛔ AND THE PR-OWNER LOCK IS THE THIRD, NAMED FOR THE SAME REASON (review of PR #2576, P2).
# `fix-one.sh` now defers — also rc=0, also nothing pushed — when a LANDER holds
# `mergeclaim-<PR>.lock`, because a push there would move the head out from under the attestation the
# lander is landing. Without this arm an operator reading `adopt-$PR.log` (the log THIS script exists
# to fill, #1720) saw no line at all and got SUCCESS for a run that did nothing, and a `… && next`
# chain took the wrong branch. It is 79: a deferral stops the chain, and a deferral that will clear by
# itself is exactly what 79 says.
# The token is `DEFERRED: the LANDER` — `fix-one.sh`'s deferred line is `[fix <PR>] DEFERRED: <why>`, so
# this matches the CAUSE, never a substring shared with the `DEFERRED: the PR-owner lock` arm below.
elif [ "$rc" = "0" ] && grep -q 'DEFERRED: the LANDER' "$O/logs/fix-$PR.log" 2>/dev/null; then
  echo "[adopt-fix $PR] fixer NOT started (PR-OWNER lock) — a lander owns this PR right now (review/record/merge in flight), so nothing was pushed and no attempt was consumed; the holder and the reason are in $O/logs/fix-$PR.log. Re-run once the lander finishes (it lands the PR, or refuses and releases)." >> "$O/logs/adopt-$PR.log"
  exit 79
elif [ "$rc" = "0" ] && grep -q 'DEFERRED: the PR-owner lock' "$O/logs/fix-$PR.log" 2>/dev/null; then
  # ⛔ THE REPAIR IS NAMED (review of PR #2576, cycle 2 — P2). A STALE claim is now TAKEN OVER by
  # `fix-one.sh` itself (#2574 (b)), so this arm is reached only when the takeover lost a race with a
  # peer that reclaimed it first, or when the record's content could not be proven dead (empty — a
  # lander mid-claim — or unparseable). Neither is a state `adopt-fix` can fix by retrying blindly, and
  # the reclaim the older wording promised (the controller's next dispatch) never comes on this
  # surface, because this script exists for the case where nothing is dispatching the PR.
  echo "[adopt-fix $PR] fixer NOT started (PR-OWNER lock, not reclaimable) — the lock's holder could not be proven dead (empty/unparseable content, so it is treated as LIVE), or the takeover displaced a peer's claim and could not restore it; nothing was pushed and no attempt was consumed. If this persists and NO worker is live, REPAIR: confirm none is running (pgrep -af 'fix-one.sh|merge-one.sh|cloud-cell-doctor.sh' — a live FIXER also holds this lock, for the whole agent run), then rm -f \"$O/state/mergeclaim-$PR.lock\" and re-run. The exact line is in $O/logs/fix-$PR.log." >> "$O/logs/adopt-$PR.log"
  exit 79
# ... and a REFUSAL that can never clear by itself is named here too, with its own repair. It is NOT
# refundable in fix-one.sh (a re-dispatch cannot change a lock path that is not a lock file, or an
# unwritable state dir), so an operator who only sees "success" would re-run it for ever.
# ⛔ BUT DO NOT PROMISE A PARK THIS SURFACE CANNOT PRODUCE (review of PR #2576, P3): `adopt-fix` calls
# fix-one positionally, so `CTRL=0` — no attempt was booked here, and no controller is dispatching (that
# is this script's premise). The consequence exists on the CONTROLLER path only, and the operator must
# not wait for a park that cannot arrive.
elif [ "$rc" = "0" ] && grep -q 'REFUSED (NOT refundable' "$O/logs/fix-$PR.log" 2>/dev/null; then
  echo "[adopt-fix $PR] fixer NOT started (PR-OWNER lock, UNUSABLE) — the lock path cannot be read or created, which no re-dispatch can change, so fix-one.sh does NOT refund it (a CONTROLLER-dispatched run would consume an attempt and park the PR for a human; this manual run booked nothing, so nothing was consumed here). Nothing was pushed. The repair command is in $O/logs/fix-$PR.log." >> "$O/logs/adopt-$PR.log"
  exit 79
# ⛔ THE CROSS-BOX REFUSAL IS THE FOURTH, AND IT WAS THE ONE STILL REPORTING SUCCESS (review of PR
# #2576, P3). `fix-one.sh` refuses — also rc=0, also nothing pushed — when another BOX already holds
# `refs/claims/<PR>-<head12>`, and its line is `cross-box fixer claim REFUSED: …`, with no `DEFERRED`
# token of its own. Without this arm the operator's log got no line and the exit status said
# SUCCESS for a run that did nothing — the same class the two arms above were added to close.
elif [ "$rc" = "0" ] && grep -q 'cross-box fixer claim REFUSED' "$O/logs/fix-$PR.log" 2>/dev/null; then
  echo "[adopt-fix $PR] fixer NOT started (CROSS-BOX claim) — another box is already fixing this head, so nothing was pushed and no attempt was consumed; re-run once that worker finishes or its lease expires. The holder and the head are in $O/logs/fix-$PR.log." >> "$O/logs/adopt-$PR.log"
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
