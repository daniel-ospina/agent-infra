> **Step 1/5** | → next: `02-research-intake.md`

## Prerequisite Check (GitHub Issues Only)

**If working from a GitHub issue** (issue number is provided or referenced):

1. Run `gh issue view <number> --comments` and check for either `<!-- issue-scoping:` or `<!-- issue-planning:` in the output using: `grep -E '<!-- issue-(scoping|planning):'`
   <!-- backwards-compat: also accepts issue-planning:* signatures from pre-rename planned issues -->
2. If the signature is **absent**: stop and prompt the user —
   > "This issue hasn't been processed by `issue-scoping` yet. Run the `issue-scoping` skill first to define requirements, priorities, and scope. Then return here for implementation planning."
3. If the signature is **present**: proceed. The requirements, priorities, and needs are already captured. This skill focuses on **design decisions and implementation steps** not already covered there.

**Epic doc check (runs after the issue-scoping signature is confirmed):**

4. Search the issue body for a line matching `**Epic:** docs/epics/` (case-insensitive):
   ```bash
   gh issue view <number> --json body --jq '.body' | grep -i 'Epic:.*docs/epics/'
   ```
5. If an epic reference is found:
   - Read the referenced epic doc (e.g. `docs/epics/2026-03-05-notification-system-v2.md`) in full before drafting the plan
   - The epic doc is the architecture contract. The implementation plan must be consistent with it: same data model, same migration phases, same component boundaries
   - If any design decision in this plan would conflict with the epic doc, stop and note the conflict explicitly — do not silently diverge. Ask the user whether to update the epic doc or adjust the plan.
6. If no epic reference is found: proceed without this check.

**If working from a spec/requirements document** (no GitHub issue): skip this check and proceed directly.

## Tier Detection (GitHub Issues Only)

After the prerequisite check passes, read the issue's complexity label:

```bash
gh issue view <ISSUE_NUMBER> --json labels --jq '.labels[].name' | grep '^complexity:'
```

- If `complexity:micro` → **TIER = Micro**
- If `complexity:standard` → **TIER = Standard**
- If `complexity:complex` → **TIER = Complex**
- If no `complexity:*` label found → **TIER = Complex** (safest default)

Store as `TIER` for all decisions below.

## Worktree Isolation Check (all tiers)

**Purpose:** Prevent worktree collisions when multiple sub-agents are dispatched concurrently from the same epic worktree (observed during #2968 delivery — see #2987 Obs 2). When invoked from inside a worktree that doesn't belong to this issue, the agent must create its own isolated worktree before proceeding.

1. Check if currently inside a git worktree:
   ```bash
   GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
   if [ "$GIT_DIR" != ".git" ] && [ "$GIT_DIR" != "$(pwd)/.git" ]; then
     echo "WORKTREE_ACTIVE"
     CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   fi
   ```

2. Determine the expected branch for this issue/feature. If an issue number is available, derive from it: `feat/<ISSUE_NUMBER>-<slug>` or `plan/<ISSUE_NUMBER>-<slug>`.

3. **If `WORKTREE_ACTIVE` and the current branch does NOT match the expected branch** for this issue's work (e.g. you're on `epic/qr-scan-personalization` but need `plan/2973-cf-function-flip`):
   - **Stop.** Do NOT `git checkout -b` inside this worktree — that will steal the worktree from any sibling agent using it.
   - Invoke the `using-git-worktrees` skill to create a fresh, isolated worktree for this issue.
   - Re-enter the new worktree and restart from Step 1.

4. **If `WORKTREE_ACTIVE` and the current branch matches or is compatible**, proceed normally.

5. **If NOT in a worktree**, proceed normally — `writing-plans` will create one for Complex tier in Step 4.

**Rationale:** Without this check, concurrent sub-agents running `git checkout -b` inside a shared epic worktree silently repoint the worktree's branch, causing sibling agents to lose their working state (observed: Agent A for #2969 had to recover via patch when Agent E repointed the worktree). The check is cheap (one `git rev-parse`) and prevents hours of recovery work.
