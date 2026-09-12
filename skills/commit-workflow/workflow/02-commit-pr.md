> **Step 2/5** | ← requires: `01-preflight.md` | → next: `03-code-review.md`

# Commit + Pull Request

## Step 1 — Commit + Draft PR

```bash
# Pre-lint before staging so lint-staged's stash backup/restore cycle is a no-op
npx eslint --fix <relevant files>

# Stage relevant files (specific paths, not git add -A)
git add <relevant files>

# Commit — the message goes to a file, and the commit reads that file with -F.
# ⛔ NEVER `git commit -m "…"`. NEVER a heredoc. Both let the shell parse the
#    message before git sees it — see "⛔ Commit messages" below.
# #729: never /tmp/commit-msg-<branch>.md — a branch name is unique per repo,
#       not globally, so concurrent sessions in different repos collide there.
#       The file goes in a REPO+WORKTREE-UNIQUE temp dir, keyed by the cksum of
#       the absolute git dir.
#       ⛔ NOT under `.git/`: main-worktree-guard freezes `.git/…` writes as
#          "hub git-metadata" for every unhatched session (the fleet default for
#          `task` children), so that write is blocked.

# ── CALL 1 of 4: learn the path ─────────────────────────────────────
echo "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
# → e.g. /var/folders/…/T/pi-commit-msg-3198440152/fix-729-commit-msg-path.md
#   `tr '/' '-'` sanitizes a slash-bearing branch; the cksum is per-repo AND
#   per-worktree (`--absolute-git-dir` differs per linked worktree).

# ── CALL 2 of 4: `write` the message to that path (the write tool bypasses bash) ──
#   <type>(<scope>): <subject>
#
#   Closes #ISSUE_NUMBER

# ── CALL 3 of 4: commit ─────────────────────────────────────────────
# ⛔ Do NOT assign MSG in this call. Two independent reasons:
#    (a) every bash call is a FRESH SHELL, so a `MSG=…` set in CALL 1 is unset
#        here — `-F "$MSG"` would read an EMPTY path, and `rm -f "$MSG"` would
#        silently delete nothing (this is exactly what orphaned 12 message files);
#    (b) assigning a variable in the same call as the commit is refused by the
#        verification gate as an "in-batch mutation chain".
#    Inline the substitution instead — self-contained and gate-safe:
git commit -F "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"

# ── CALL 4 of 4: delete the message file (re-derive; never reuse a variable) ──
rm -f "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
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

```bash
# Resolve the per-repo message path (#729) — worktree-aware, collision-free.
# This is CALL 1; the path must be known before the `write` tool can be used.
# Echo the substitution rather than assigning a variable: a `MSG=…` set here
# would be UNSET in the call that commits, which is how the empty-path bug
# happened in the first place.
echo "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
# → /var/folders/…/T/pi-commit-msg-3198440152/fix-668-commit-msg.md
#   (in a linked worktree: that worktree's own gitdir under .git/worktrees/)
```

```text
write  <the absolute path printed above>

  fix(commit-workflow): ban -m commit messages + flag mangled ones (#668)

  `git commit -m "…"` lets the shell eat backticked spans before git sees
  them: the message "which tolerates `key :` — and anchors" commits as
  "which tolerates  — and anchors". New commit-msg hook warns on the
  signature: unbalanced backticks or a doubled space where code should be.

  Closes #668
```

```bash
# then, in bash — the message never appears on the command line.
# This is a SEPARATE call, so no variable survives: inline the substitution.
# (Assigning MSG here would ALSO be refused by the verification gate.)
git commit -F "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"

# separate call — re-derive the path, never reuse a variable:
rm -f "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
```

`git commit -m` and heredocs are forbidden **everywhere** (commit messages, PR
bodies, issue comments) — the rule is about the message crossing the shell, not
about heredocs specifically.

### Mangled commit message — repair

The `.husky/commit-msg` hook warns when it sees the signature of a lost shell
substitution (unbalanced backticks, or a doubled space where inline code should
be). By default it merely warns — both signatures have realistic false
positives (a lone backtick in prose; an aligned code block) — so a warning is a
prompt to *look*, not a failure. `COMMIT_MSG_MANGLE_STRICT=1` makes it fatal.

On a hit:

1. **Not pushed yet** — amend before anything else:
   ```bash
   # `write` the corrected message to the same path first, then amend.
   # Inline the substitution: a separate call, and no variable assignment
   # may share a call with the commit (#729).
   git commit --amend -F "${TMPDIR:-/tmp}/pi-commit-msg-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
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
#    file with the `write` tool and pass --body-file, then remove the file.
#    ⛔ NOT /tmp/pr-body-<branch>.md (#729): a branch name is unique per repo, not
#       globally, so four repos on `fix/700-review-cap` collide there and
#       `gh pr create` publishes ANOTHER repo's PR description. Same derivation
#       as the commit message, with a distinct `pi-pr-body-` prefix:
#   ${TMPDIR:-/tmp}/pi-pr-body-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md
#   ## Summary
#   - <bullet 1>
#   - <bullet 2>
#
#   Closes #ISSUE_NUMBER
gh pr create --draft \
  --base main \
  --title "<title>" \
  --body-file "${TMPDIR:-/tmp}/pi-pr-body-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
rm -f "${TMPDIR:-/tmp}/pi-pr-body-$(git rev-parse --absolute-git-dir | cksum | cut -d' ' -f1)/$(git rev-parse --abbrev-ref HEAD | tr '/' '-').md"
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
