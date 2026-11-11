> **Step 5/5** | ← requires: `04-merge-deploy.md`

# Cleanup + Documentation

**Status transition:** Issue: implementing → completed (merge successful). Plan `doc_status`: live (implementation successful, plan was correct).

## Step 3.8 — Worktree Teardown

Runs on **both** auto-merge and staging paths — immediately after merge + migration deploy + verification (default path) or before emitting staging instructions (staging path). The worktree is no longer needed once the PR exists on the remote.

⛔ **The one hard constraint: this step must never remove the directory YOUR session is standing
in.** If the lane opened in its worktree — the normal case — that directory is the session's
`process.cwd()`. Every `bash` tool call spawns a **fresh shell rooted there**, so the removal leaves
the session with no working directory at all:

```
Working directory does not exist: /…/.worktrees/1145-lane
Cannot execute bash commands.
```

From that point every command fails before it runs — including the merged-branch delete below and
Steps 4-5 — so the session cannot even fix itself (#1895, measured 2026-10-16 on a DMeer lane).

⛔ **`cd "$MAIN_REPO"` does NOT prevent this, and reads as if it does.** A `cd` inside a `bash` tool
call moves only that one short-lived shell; the session's own cwd is unchanged, so removing the
directory still orphans it. Judge the hazard from the **process table**, never from `$PWD`.

`scripts/cleanup-worktree.sh` therefore refuses when a live process holds the target by cwd/exe
(exit 3, naming the holder), and also when the process table cannot be read — a census that cannot
run proves nothing about whether a session is standing in the tree. **Teardown is then DEFERRED, not
lost**: `scripts/pi-reap-worktrees.sh` reclaims the directory once nothing holds it (its `--aged-days`
floor, default 7, is the delay), which is the same #1105 "a live process holds it, so it is not yet
garbage" rule the reapers already use.

⛔ **What "not lost" does and does not promise.** A lane-rooted session now *always* takes the
deferral path (the census sees its own session), so for the common case the teardown happens later —
by the reaper, or by a fresh session that is not rooted in the tree. The reaper reclaims exactly the
trees this step would have removed, because both sides use the **same** ignored-artifact allowlist
(`IGNORED_REGENERABLE`, `scripts/pi-reap-worktrees.sh:810`). A worktree carrying anything that list
does not cover (`.env`, `data/`, a nested `dist/`) is refused here AND preserved by the reaper: it
stays for an operator. That is the safe direction, and it is why the deferral is not a licence to
leave dirt behind.

```bash
# Detect if running in a worktree
TOPLEVEL=$(git rev-parse --show-toplevel)
GIT_COMMON=$(git rev-parse --git-common-dir)

if [ "$GIT_COMMON" != ".git" ] && [ "$GIT_COMMON" != "$TOPLEVEL/.git" ]; then
  BRANCH=$(git branch --show-current)
  MAIN_REPO=$(cd "$GIT_COMMON/.." && pwd)
  # Run it from a surviving cwd. This changes only THIS shell — if the session is rooted in
  # $TOPLEVEL, the script refuses (exit 3) and teardown defers to the reaper. That refusal is the
  # expected outcome for a lane that opened in its worktree, not a failure to work around.
  ( cd "$MAIN_REPO" && bash scripts/cleanup-worktree.sh "$BRANCH" )
  # Best-effort refresh of the main checkout (WARN, never a ceremony failure): a shared hub may
  # refuse the pull outright — see Step 4 for why hub writes are the exception, not the rule.
  ( cd "$MAIN_REPO" && git pull --ff-only ) || echo "ℹ️ main checkout not fast-forwarded"
fi
```

Run it from a session that is **not** rooted in the worktree (the hub, or another lane's checkout) →
the ordinary teardown. Run it from the worktree's own session → a named refusal and a deferred
teardown.

If cleanup fails: warn and continue. Never block Steps 4-5 or staging instructions.
If not in a worktree: skip silently.

### `--force` is the dirty guard's signal, not a habit (#1895)

`cleanup-worktree.sh` refuses on a dirty worktree **including ignored files** (`git worktree remove`
does not refuse on those, so an ignored-only `.env` would otherwise be silently destroyed). A repo
whose worktree convention *requires* a real dependency tree (a hardlinked `node_modules/`, DMeer
#878) is refused on its **expected** state, so passing `--force` every time would erode the flag
exactly where it matters.

So ignored-only dirt gets a **closed** allowance: when every ignored entry is a regenerable artifact
**name** — the fleet's own `IGNORED_REGENERABLE` list (`scripts/pi-reap-worktrees.sh:810`: tool-scoped
dependency trees and caches, `node_modules`, `.venv`, `__pycache__`, `htmlcov`, `*.egg-info`, …,
matched on the basename) — the removal proceeds without `--force` and says what it is destroying. Any
tracked or untracked change, and any ignored file outside that list (`.env`, `data/`, and the
*generic* names `dist/`, `build/`, `target/`, `.next/`, `.cache`, `coverage`, `output`, which are
operator data in a nested position), still refuses unless `--force`.

⛔ **Do not widen that list here.** It is a recorded fleet decision with a measurement behind it
(the 2026-10-11 sweep: 49 of 261 live worktrees carried a non-regenerable entry, `website/apps/
dashboard/dist/` named). Widening it is a **reopen** of the `pi-reap-worktrees.sh` decision, argued in
its own home — never a side effect of a teardown script.

### Merged-branch cleanup (post-merge, #193)

Runs right after the worktree teardown above (or standalone when the session was not in a
worktree). The merged PR branch must be deleted **regardless of worktree state** — never
leave the branch for `gh pr merge --delete-branch` to clean up (that flag hard-fails when
the default branch is worktree-locked; the merge ceremony in 04-merge-deploy.md already
handled deletion separately).

⛔ **A deferral here is the expected state, not a fault.** When the worktree is still there — the
teardown was refused because the session stands in it (#1895, above), or the removal failed — the
**remote** delete still runs (it is server-side and unaffected), and the **local** branch delete
defers with the note below. The reaper removes the worktree once nothing holds it; `git branch -D`
becomes possible then. Do not `--force` the worktree out from under a live session to make this line
clean.

```bash
# BRANCH = the merged PR branch — resolve via gh FIRST. Deriving from the current
# branch is ambiguous after the ceremony: a worktree session returns to its base
# (or is torn down) and its current checkout is no longer the PR head — and
# `git branch --show-current` would target the wrong branch. gh knows the PR's
# head branch regardless of local checkout state.
BRANCH=$(gh pr view <PR_NUMBER> --json headRefName -q '.headRefName' 2>/dev/null)
[ -n "$BRANCH" ] || BRANCH=$(git branch --show-current)

# Remote delete — server-side; run it AFTER the teardown above. The #73
# coordinated-delete guard blocks deleting a branch still checked out in ANY
# worktree, and it matches the LITERAL ref in the command text. ⛔ An unresolvable
# target — "$BRANCH", a $(…) substitution, a glob, a brace expansion — is REFUSED
# fail-closed since #653: the guard cannot tell which ref it would delete.
#   → STEP 1: read the merged branch:   echo "git push origin --delete $BRANCH"
#   → STEP 2: REPLACE REPLACE-WITH-PR-BRANCH below with the ref that prints, then run it.
# "remote ref does not exist" means deleteBranchOnMerge already removed it = success.
git push origin --delete feat/REPLACE-WITH-PR-BRANCH 2>/dev/null \
  || echo "⚠️ remote delete did NOT run for feat/REPLACE-WITH-PR-BRANCH — substitute the PR branch from STEP 1 and re-run, or: gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/<that-ref>"

# Local delete — best-effort. If the worktree was removed above the branch is no
# longer checked out, but the HUB's main-checkout branch-force-delete gate still
# blocks a branch that is not the session's baseline or pid-owned (a `git worktree
# add -b` branch is never recorded as owned — create-new is blocked, #626). A block
# or git refusal is a WARN — never fail the ceremony. A GUARD block rejects the bash
# call before the shell runs, so the `||` echo below never fires on it: the agent
# must surface the teardown note itself.
if git worktree list --porcelain | grep -q "branch refs/heads/$BRANCH"; then
  echo "⚠️ branch $BRANCH is still checked out in a worktree — local delete deferred."
  echo "   TEARDOWN NOTE: remove the worktree and run: git branch -D $BRANCH"
else
  git branch -D "$BRANCH" 2>&1 || echo "⚠️ local branch $BRANCH not deleted (guard-blocked or missing) — remove manually: git branch -D $BRANCH"
fi
```

This satisfies the #193 contract: the merged branch is deleted even when `main` is
permanently locked by other worktrees, and a failed cleanup is a WARN — never a block.

## Step 4 — Documentation & memory verification (post-merge, READ-ONLY)

⛔ **This step writes nothing.** The memory/doc write-back was done **pre-commit, in
the worktree**, by `02-commit-pr.md` Step 0 — so it rides the work PR and is covered
by that PR's review. This step only VERIFIES that it landed and carries out the
read-only post-merge audits.

### Why this step is read-only (#648)

Step 3.8 (above) tears the session's worktree down **immediately after the merge**,
and this step runs after that. The only checkout then in reach is the **shared hub**,
which in a multi-session fleet belongs to whichever session is currently checked out
there. A tracked hub write such as `MEMORY.md` is a destructive cross-session write:
main-worktree-guard blocks it (#618/#621/#625), and before that guard the naive
implementation destroyed a parallel session's 3 uncommitted `MEMORY.md` lines —
recoverable only because they were still in the writing agent's context (the
#644/#623 incident recorded in #648). A post-merge edit here is therefore either
**inert** (blocked by the guard), **destructive** (pre-guard), or **PR pollution**
(a dirty hub swept into whichever branch the next session commits from).

### Verify (read-only)

1. **Memory** — if the work surfaced a code gotcha, the merged PR's own diff carries
   the `MEMORY.md` line:

```bash
gh pr view "$PR_NUMBER" --json files -q '.files[].path'
```

2. **Docs** — the same diff carries any `docs/` / `skills/**` update the change
   warranted. To identify the applicable areas, READ
   `docs/teams/organisation-design-team/domains (S1)/operations/00_index.md` (eldato
   repo — fetch it with `gh api repos/daniel-ospina/eldato/contents/<path> --jq
   .content | base64 -d`) and check the linked GitHub issue for explicit doc-update
   notes.
3. **Missed?** A gotcha/doc change the PR does **not** carry is a **missed
   write-back** — it is NOT fixed here. Use the micro follow-up PR route below.

### If something is missing — micro follow-up PR (never a hub write)

The sanctioned route is the same one the merged-branch guard already uses for
already-merged work (`01-preflight.md`): its own worktree, off fresh `origin/main`,
`Refs #<THIS_ISSUE>` in the PR body.

```bash
# One command, from the hub (or any checkout of the repo) — creates the worktree:
bash scripts/checkout-hygiene/hub-worktree.sh docs/memory-<slug>
# Then, INSIDE that worktree: make the memory/doc edit, commit, push, open the PR.
```

⛔ Never `printf … >> MEMORY.md`, never the `edit`/`write` tool on a hub `MEMORY.md`,
and never `git commit` in the hub — that is the destructive write this step exists to
prevent.

### Post-merge audits (read-only, non-blocking)

4. **Post-merge label audit** — verify the linked issue has a `complexity:` label:

```bash
ISSUE=$(gh pr view "$PR_NUM" --json body -q '.body' | grep -oP '#\K\d+' | head -1 2>/dev/null || true)
if [ -n "$ISSUE" ]; then
  HAS_COMPLEXITY=$(gh issue view "$ISSUE" --json labels -q '.labels[].name' 2>/dev/null | grep -c '^complexity:' || echo 0)
  if [ "$HAS_COMPLEXITY" -eq 0 ]; then
    echo "WARNING: Issue #$ISSUE closed without a complexity: label. Add one manually."
  fi
fi
```

   Non-blocking — warn only. Missing labels do not prevent merge.

5. **Epic doc staleness check** — if the PR references an epic (label `epic/*` or closes an issue linked to an epic doc), verify the epic doc is not stale:

```bash
# Find epic doc from issue labels or PR body
EPIC_DOC=$(gh issue view "$ISSUE" --json labels -q '.labels[].name' 2>/dev/null | grep '^epic/' | head -1)
if [ -n "$EPIC_DOC" ]; then
  # Check: does epic doc Status match actual issue states?
  # Check: is Decisions Log populated if the merged PR made decisions?
  # Check: are Learnings updated for notable findings?
  echo "INFO: This PR closes an epic issue. Verify the epic doc is up to date:"
  echo "  - Status header (does it reflect actual issue states?)"
  echo "  - Decisions Log (did this PR make decisions worth recording?)"
  echo "  - Learnings (did this PR produce notable findings?)"
fi
```

   Non-blocking — informational only. Epic doc drift is a documentation gap, not a deploy blocker.

If nothing relevant changed, skip silently.

## Step 5 — Documentation & memory verification checklist

Read-only. Verify the write-back the PR carried — by READING the merged diff, never
by writing (Step 4):

```
For each memory/doc update the work warranted:
  ✓ Present in the merged PR's diff?
  ✓ Factually correct given the work done?
  ✓ Complete — nothing important omitted?
  ✓ Not excessive — no padding or speculation?

If any ✗: the remedy is a micro follow-up PR (Step 4) — NOT an in-place hub edit.
```

The write-time self-review of the last three questions is in `02-commit-pr.md`
Step 0 — that is where a ✗ is still fixable inside the same PR.
