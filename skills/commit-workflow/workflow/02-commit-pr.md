> **Step 2/5** | ← requires: `01-preflight.md` | → next: `03-code-review.md`

# Commit + Pull Request

## Step 1 — Commit + Draft PR

```bash
# Pre-lint before staging so lint-staged's stash backup/restore cycle is a no-op
npx eslint --fix <relevant files>

# Stage relevant files (specific paths, not git add -A)
git add <relevant files>

# Commit
git commit -m "$(cat <<'EOF'
<type>(<scope>): <subject>

Closes #ISSUE_NUMBER
EOF
)"
```

**IMPORTANT — commit timeout:** Always run `git commit` **foreground** with `timeout: 300000` (5 minutes minimum). Never set `run_in_background: true` for `git commit`. Never use a timeout below 300 seconds. The pre-commit hook (lint-staged running ESLint on staged TS files) takes 20–90 seconds. Killing it mid-run orphans the lint-staged backup stash and leaves `.git/index.lock` behind — causing exit code 128 on every subsequent commit until the lock is manually removed. This timeout rule also applies to all fix-loop `git commit` calls in Steps 2 and 2.5.

```bash
# Push and open as DRAFT
git push -u origin <branch>
gh pr create --draft \
  --base main \
  --title "<title>" \
  --body "$(cat <<'EOF'
## Summary
- <bullet 1>
- <bullet 2>

Closes #ISSUE_NUMBER
EOF
)"
```

The PostToolUse hook fires on `gh pr merge` as a safety net for manual merges outside commit-workflow. Step 2 is the primary code-review gate.

## Step 1.5 — Fallback Tier Classification (only if TIER = unknown)

Skip if TIER was resolved in pre-flight. Proceed directly to the auto-reclassification check below.

Inspect the PR diff for tier signals:

```bash
# List changed files
gh pr diff <PR_NUMBER> --name-only

# Count added lines (for Micro threshold — additions only, avoids double-counting renames)
# Use '^+[^+]' to exclude '+++ b/filename' diff headers
gh pr diff <PR_NUMBER> | grep -c '^+[^+]' 2>/dev/null || echo 0
```

Classification rules (first match wins):
- Any file matching `supabase/migrations/` or `supabase/functions/` → **Complex**
- File count = 1 AND added line count < 20 → **Micro**
- Otherwise → **Standard**

Apply the label and post a FYI comment (skip if `ISSUE_NUMBER = 'none'`):

```bash
if [ "$ISSUE_NUMBER" != "none" ]; then
  gh issue edit $ISSUE_NUMBER --add-label "complexity:X"
  gh issue comment $ISSUE_NUMBER --body "Auto-classified as \`complexity:X\` based on diff analysis."
fi
```

Update `TIER` with the result.

## Step 1.6 — Auto-Reclassification Check (always runs if ISSUE_NUMBER is resolved)

Skip if `ISSUE_NUMBER = 'none'`.

If TIER is Micro or Standard AND the diff contains any file in `supabase/migrations/` or `supabase/functions/`:

```bash
OLD_TIER=$TIER
TIER="complex"
gh issue edit $ISSUE_NUMBER --remove-label "complexity:$OLD_TIER" --add-label "complexity:complex"
gh issue comment $ISSUE_NUMBER --body "Reclassified from \`complexity:$OLD_TIER\` → \`complexity:complex\` because migration or edge function file detected in diff. Adjusting workflow."
```
