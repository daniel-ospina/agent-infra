> **Step 2/5** | ← requires: `01-preflight.md` | → next: `03-code-review.md`

# Commit + Pull Request

## Step 1 — Commit + Draft PR

```bash
# Pre-lint before staging so lint-staged's stash backup/restore cycle is a no-op
npx eslint --fix <relevant files>

# Stage relevant files (specific paths, not git add -A)
git add <relevant files>

# Commit — write the message with the `write` tool (it bypasses bash entirely)
# to a deterministic path, then commit with -F and remove the file.
# ⛔ NEVER `git commit -m "…"`. NEVER a heredoc. Both let the shell parse the
#    message before git sees it — see "⛔ Commit messages" below.
#   /tmp/commit-msg-<branch>.md
#   <type>(<scope>): <subject>
#
#   Closes #ISSUE_NUMBER
git commit -F /tmp/commit-msg-<branch>.md
rm -f /tmp/commit-msg-<branch>.md
```

**IMPORTANT — commit timeout:** Always run `git commit` **foreground** with `timeout: 300000` (5 minutes minimum). Never set `run_in_background: true` for `git commit`. Never use a timeout below 300 seconds. The pre-commit hook (lint-staged running ESLint on staged TS files) takes 20–90 seconds. Killing it mid-run orphans the lint-staged backup stash and leaves `.git/index.lock` behind — causing exit code 128 on every subsequent commit until the lock is manually removed. This timeout rule also applies to all fix-loop `git commit` calls in Steps 2 and 2.5.

### ⛔ Commit messages: `-F` always — never `-m`, never a heredoc

`git commit -m "…"` is the *same* hazard as the heredoc #194 banned — **the
shell parses the message before git ever sees it.** Inside double quotes,
backticked spans are command substitution, `$VAR`/`$(…)` expand, and `${…}` /
`{{ }}` break. The substitution usually yields an **empty string**, so the
failure is silent: git accepts the mangled message and only a human reading the
log sees the hole. Both of these happened while landing #640 (#668):

```sh
# source message contains a backticked span
#   … key matching via keyRe() which tolerates `key :` — and anchors …
git commit -m "fix(ci): … keyRe() which tolerates \`key :\` — and anchors …"
# COMMITTED AS (span eaten, silent):
#   … keyRe() which tolerates  — and anchors …

# the substitution actually runs:
#   bash: key: command not found
git commit -m "fix(ci): … set the binding to \`|| true\` …"
```

Both mangles were pushed before anyone noticed and each cost an `--amend` +
force-push. Author the message with the **`write` tool** — it bypasses bash
entirely, so nothing in the message is ever interpreted:

```text
write  /tmp/commit-msg-668.md

  fix(commit-workflow): ban -m commit messages + flag mangled ones (#668)

  `git commit -m "…"` lets the shell eat backticked spans before git sees
  them: the message "which tolerates `key :` — and anchors" commits as
  "which tolerates  — and anchors". New commit-msg hook warns on the
  signature: unbalanced backticks or a doubled space where code should be.

  Closes #668
```

```bash
# then, in bash — the message never appears on the command line:
git commit -F /tmp/commit-msg-668.md
rm -f /tmp/commit-msg-668.md
```

`git commit -m` and heredocs are forbidden **everywhere** (commit messages, PR
bodies, issue comments) — the rule is about the message crossing the shell, not
about heredocs specifically.

### Mangled commit message — repair

The `.husky/commit-msg` hook warns when it sees the signature of a lost shell
substitution (unbalanced backticks, or a doubled space where inline code should
be). It is **warn-only** by default — both signatures have realistic false
positives (a lone backtick in prose; an aligned code block) — so a warning is a
prompt to *look*, not a failure. `COMMIT_MSG_MANGLE_STRICT=1` makes it fatal.

On a hit:

1. **Not pushed yet** — amend before anything else:
   ```bash
   # rewrite /tmp/commit-msg-<branch>.md with the `write` tool first
   git commit --amend -F /tmp/commit-msg-<branch>.md
   ```
2. **Pushed, branch under review** — do **not** silently force-push the
   rewritten message. Post a correction note on the PR/issue (what was wrong,
   what it now says), *then* `git push --force-with-lease`. A silently rewritten
   record is exactly what happened twice on #640; a visible correction is the
   point.
3. **Pushed, not under review** — `git commit --amend -F …` then
   `git push --force-with-lease` is safe.

```bash
# Push and open as DRAFT
git push -u origin <branch>
# ⛔ Same rule as the commit message: never pass the PR body through the shell.
#    `--body "…"` and `--body "$(cat <<'EOF' …)"` both let the shell eat
#    backticked spans / expand `$()` and `{{ }}`. Write the PR body to a temp
#    file with the `write` tool and pass --body-file, then remove the file:
#   /tmp/pr-body-<branch>.md
#   ## Summary
#   - <bullet 1>
#   - <bullet 2>
#
#   Closes #ISSUE_NUMBER
gh pr create --draft \
  --base main \
  --title "<title>" \
  --body-file /tmp/pr-body-<branch>.md
rm -f /tmp/pr-body-<branch>.md
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
- All changed files are docs (`*.md`), styles (`*.css`/`*.scss`), or static pages (`*.html` — e.g. `website/*.html`/`docs/**/*.html`, NOT build-output templates like `public/index.html`) → **Micro** (gate consequences, aligned with shipped enforcement per 01-preflight.md's Micro Tier table: pre-flight risk Low → typecheck/build skip; code review skipped at Micro per 03-code-review.md; review-enforcer blocks at 0 dispatches at EVERY tier — micro included, since #485 — and a code-bearing micro set satisfies the ≥1 dispatch via VGATE's own [VGATE] verification dispatch, while a docs-only micro set dispatches a lightweight reviewer naming the diff. The VGATE skip is NOT a Micro-tier consequence: VGATE's exemption is content-SHAPE-based and tier-independent — this same docs/CSS/static file class (`.md|.css|.scss|.html`, no `public/|dist/|build/` path segment) skips VGATE at ANY tier per the VGATE-SHAPE-RULE fence, and code-bearing micro sets never skip)
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
