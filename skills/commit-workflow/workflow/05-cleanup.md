> **Step 5/5** | ← requires: `04-merge-deploy.md`

# Cleanup + Documentation

**Status transition:** Issue: implementing → completed (merge successful). Plan `doc_status`: live (implementation successful, plan was correct).

## Step 3.8 — Worktree Teardown

Runs on **both** auto-merge and staging paths — immediately after merge + migration deploy + verification (default path) or before emitting staging instructions (staging path). The worktree is no longer needed once the PR exists on the remote.

```bash
# Detect if running in a worktree
TOPLEVEL=$(git rev-parse --show-toplevel)
GIT_COMMON=$(git rev-parse --git-common-dir)

if [ "$GIT_COMMON" != ".git" ] && [ "$GIT_COMMON" != "$TOPLEVEL/.git" ]; then
  BRANCH=$(git branch --show-current)
  MAIN_REPO=$(cd "$GIT_COMMON/.." && pwd)
  cd "$MAIN_REPO"
  bash scripts/cleanup-worktree.sh "$BRANCH"
  git pull
fi
```

If cleanup fails: warn and continue. Never block Steps 4-5 or staging instructions.
If not in a worktree: skip silently.

## Step 4 — Documentation Update

After merge, update relevant documentation (scope: only what actually changed):

1. Read `docs/teams/organisation-design-team/domains (S1)/operations/00_index.md` (eldato repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`) to identify applicable documentation areas
2. Check the linked GitHub issue for explicit doc update notes
3. Update as appropriate:
   - `MEMORY.md` — if architectural decisions, key files, or patterns changed
   - `docs/` files — if features, APIs, or workflows changed
   - No speculative edits, no padding

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

## Step 5 — Documentation Self-Review

Review all edits from Step 4:

```
For each doc change:
  ✓ Factually correct given the work done?
  ✓ Complete — nothing important omitted?
  ✓ Not excessive — no padding or speculation?

If any ✗: fix and re-review
Loop until all ✓
```
