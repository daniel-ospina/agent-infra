> **ARCHIVED — DO NOT USE.** This file is a snapshot of the Pi-adapted `code-review` skill (v2.0.0) preserved for historical reference. It was the active version at `operations/skills/code-review/SKILL.md` prior to reconciliation on 2026-05-24. After reconciliation, `operations/skills/code-review/SKILL.md` tracks the Claude Code canonical at `~/.claude/skills/code-review/SKILL.md` (v1.8.0, NVIDIA-aware).
>
> **Why preserved:** This Pi v2.0.0 fork has unique content not in canonical (Standard-Tier Review flag, False Positives to Ignore list, simplified fixer loop, consolidated 4-reviewer architecture). If the Pi runtime is ever re-activated, this file can serve as the starting point for re-forking from canonical via a documented transformation (strip NVIDIA/MCP refs, replace with native equivalents).
>
> **Living Pi local copy:** still exists at `~/.pi/agent/skills/code-review/SKILL.md` (last edited 2026-05-12). That tree was not deleted; it is dormant but reachable if Pi runtime is revived.

---

---
name: code-review
description: Code review a pull request
version: 2.0.0
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---

> **Sync note:** Local copy at `~/.pi/agent/skills/code-review/SKILL.md`. Repo copy at `operations/skills/code-review/SKILL.md`. Keep in sync.
>
> **Fork note:** v2.0.0 — stripped NVIDIA/MCP tool calls. Consolidated 5 reviewers into 4 (merged CLAUDE.md + code comments into Guidance Compliance). Confidence scoring via isolated Pi `task` sub-agents. Simplified fixer loop (direct sub-agent, 3 cycles max). Restored `--standard-tier` flag. Kept Research Resolution Gate and Supabase logging.

# Code Review

Provide a code review for the given pull request.

## Arguments

`code-review <PR_NUMBER> [--re-review] [--standard-tier]`

- `PR_NUMBER`: the pull request number to review
- `--re-review`: follow-up review after fix commits; see Smart Re-Review
- `--standard-tier`: reduced 2-agent review (Guidance Compliance + Bug Scan only)

**Routing:**
- `--standard-tier` present → skip to **Standard-Tier Review**
- `--re-review` present (without `--standard-tier`) → skip to **Smart Re-Review**
- Neither flag → follow steps 1–9 below

## Process (Full Review)

### Step 0 — Test Coverage Check (MANDATORY, always runs)

Before reviewing code, check whether source changes are accompanied by test changes:

```bash
# List source files changed in the PR (exclude test files, type defs, config)
gh pr diff <PR_NUMBER> --name-only | grep -E '\.(ts|tsx)$' | grep -v '\.test\.' | grep -v '\.d\.ts'
```

For each source file, check if its test file was also changed:
- `src/components/Foo.tsx` → check `src/components/Foo.test.tsx`
- `src/hooks/useBar.ts` → check `src/hooks/useBar.test.ts`

**If source changed but test did not**: flag as a P1 issue with `check_type: test-coverage-gap`. Include in the review output:
```
ISSUE:
  check_type: test-coverage-gap
  severity: P1
  location: <changed source file>
  description: Source file changed without corresponding test file update.
    <test file> was not modified. Tests may be stale.
  suggestion: Verify tests still pass and cover the changed behavior.
    Update tests if the source change affects behavior.
```

**Exceptions** (do NOT flag):
- The change is purely cosmetic (formatting, comments, import reordering)
- The changed file has no test file (new module, config file, type definition)
- The PR description explicitly states tests are not needed

### Step 1 — Eligibility Check

Dispatch a sub-agent via Pi `task` to check if the PR (a) is closed, (b) does not need review (automated, trivial, obvious), or (c) already has a code review. If ineligible, stop. **Draft PRs are eligible.**

### Step 2 — CLAUDE.md File List

Dispatch a sub-agent to list relevant CLAUDE.md file paths: root CLAUDE.md and any in directories the PR modified. Return paths only, not contents.

### Step 3 — PR Summary

Dispatch a sub-agent to read the PR diff via `gh pr view <N> --json body,title,commits` and `gh pr diff <N>`. Return a summary of the change.

### Step 3.5 — Research Brief Resolution

Resolve a research brief if one exists for the linked issue:

```bash
ISSUE_NUMBER=$(gh pr view <PR_NUMBER> --json closingIssuesReferences --jq '.closingIssuesReferences[0].number')
if [ -n "$ISSUE_NUMBER" ]; then
  ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body --jq '.body')
  RESEARCH_PATH=$(bash scripts/_research_path.sh --issue-body "$ISSUE_BODY" --epic-path "")
  if [ -n "$RESEARCH_PATH" ] && [ -f "$RESEARCH_PATH" ]; then
    RESEARCH_KIND=natural
    RESEARCH_CONTENT=$(cat "$RESEARCH_PATH")
  fi
fi
```

If `RESEARCH_KIND=natural`, inject before every reviewer sub-agent prompt:

```
## Verified Research Context (author-provided)

Treat this as authoritative; weigh findings against it. Downgrade reviewer recommendations that contradict it.

{RESEARCH_CONTENT}

---
```

### Step 4 — Parallel Review (4 agents)

Launch 4 agents **in parallel** via Pi `task`. Each receives the PR diff, CLAUDE.md paths, affected files, and research context (if any). Each returns `ISSUE:` blocks or `NO ISSUES FOUND`.

**Agent #1 — Guidance Compliance** (merged CLAUDE.md + code comments):
```
Audit the PR changes against:
1. CLAUDE.md guidance — all relevant CLAUDE.md files. Note: CLAUDE.md is guidance for writing code, so not all instructions apply during review.
2. Code comments — IMPORTANT/MUST/keep-in-sync/JSDoc contracts in modified files. Flag violations of binding comments.

For each issue found, return:
ISSUE:
  check_type: CLAUDE.md-adherence|comment-compliance
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
```

**Agent #2 — Bug Scan**:
```
Shallow scan of the PR diff for obvious bugs. Focus on the changes themselves — avoid reading extra context.
Look for: null pointer dereferences, wrong variable, inverted condition, missing async/await, incorrect API usage.
Ignore likely false positives, pre-existing issues, linter/compiler-detectable issues.

For each issue found, return:
ISSUE:
  check_type: bug
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
```

**Agent #3 — Git History/Blame**:
```
Read git blame and history of the code modified. Identify bugs visible only in historical context:
- Regressions after a previous fix
- Removed safety checks or guards
- Repeated bugfix attempts that indicate a deeper issue
- Patterns of breakage on these files/lines

For each issue found, return:
ISSUE:
  check_type: historical-context
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <what's wrong>
  suggestion: <what to fix>
```

**Agent #4 — Previous PR Comments**:
```
Find prior PRs that touched the same files. For each prior PR, read its comments.
Flag cases where the current PR repeats an issue flagged in a past review on the same files.
Steps:
1. For each affected file: gh api '/repos/{owner}/{repo}/commits?path={file}&per_page=20'
2. Extract PR numbers from commit messages (#NNN)
3. For each prior PR: gh pr view <N> --json reviews,comments
4. Return matches

For each issue found, return:
ISSUE:
  check_type: pr-comment-history
  severity: P0|P1|P2
  location: <file path>:<line>
  description: <repeated issue from PR #N>
  suggestion: <what to fix>
```

### Step 5 — Confidence Scoring

For each issue found in Step 4, dispatch an **isolated** Pi `task` sub-agent to score confidence. Each sub-agent gets:
- The PR number, issue description + location, CLAUDE.md file paths, and this rubric:

```
Score on a scale from 0–100:
a. 0: Not confident. False positive or pre-existing issue.
b. 25: Somewhat confident. Might be real but couldn't verify.
c. 50: Moderately confident. Real issue but may be a nitpick.
d. 75: Highly confident. Very likely a real issue that will be hit in practice. Important.
e. 100: Absolutely certain. Definitely a real issue, frequent in practice.

Return ONLY the number.
```

**Dispatch strategy:** Parallel for ≤15 issues, serial with 100ms stagger for >15. Extract score with regex `\b([0-9]{1,3})\b`, clamp to 0-100, default to 0 on parse failure.

### Step 6 — Filter & Fix

Filter out issues with score < 50. If none survive → go to Step 9 (Logging), then stop.

**Fixer configuration** — read `operations/ai-workflow-tools/config.json` (defaults if missing):
- `fixer_enabled`: default `true`
- `max_fix_cycles`: default `3`
- `stall_threshold`: default `0.8`

If `fixer_enabled == false` OR `--re-review` is active → skip fixer loop, go to Step 7.

### Gate Loop — MANDATORY (Fixer + Re-Review)

Each fix cycle dispatches a FRESH fixer sub-agent, and each re-review dispatches
FRESH reviewer sub-agents. Neither has memory of prior cycles — this prevents
confirmation bias.

**Simplified Fixer Loop:**

Serialize surviving issues to JSON: `[{"severity":"P1","location":"...","description":"...","suggestion":"..."}]`

For each cycle (max `max_fix_cycles`):

1. **Dispatch fixer sub-agent** via Pi `task` (fresh `pi -p` session):
   ```
   Fix these code-review issues in the current branch. Do NOT create a worktree.
   
   Issues to fix:
   <surviving issues JSON>
   
   Affected files: <list from PR diff>
   PR branch: <branch name>
   
   1. Checkout the PR branch if not already on it
   2. For each issue, make the minimal fix
   3. Commit with message: fix(code-review): automated fixer cycle N — PR #<N>
   4. Push
   
   Return FILES_WRITTEN: <comma-separated> and STATUS: done|failed.
   ```

2. **Re-review**: Run `--re-review` on the new commits. This dispatches FRESH reviewer
   sub-agents via `task` — they see only the current code, not what was "just fixed."

3. **Stall detection**: Hash each surviving issue's location+description+suggestion. If ≥`stall_threshold` of fingerprints match previous cycle → stall, exit.

**Exit conditions — ALL must be true before proceeding to Step 8:**

- [ ] Last `--re-review` returned zero issues with confidence ≥ 50
- [ ] If cycle 1 found any issues → at least 1 re-review cycle completed
- [ ] Cycle log posted: each cycle's issues, fixes, and re-review results documented

**Hard cap:** `max_fix_cycles` cycles (default 3). On cap → document remaining issues,
post with `⚠️ Auto-fix reached cycle cap (N) — M issues remain`, proceed to Step 8.

**Exit outcomes:**
- `STATUS=failed` → fixer couldn't push. Post with `⚠️ Auto-fix failed (push error) — N issues remain`.
- **Stall detected** → Post with `⚠️ Auto-fix stalled after N cycles — M issues remain`.
- **Cycle cap reached** → Post with `⚠️ Auto-fix reached cycle cap (N) — M issues remain`.
- **Clean** → no issues after re-review. Proceed to Step 8 with "No issues found."

**Critical: remaining issues are NEVER dropped.** They are always included in the PR comment body alongside the warning prefix. The fixer loop exits, but the issues persist in the review.

**FORBIDDEN — these bypass the quality gate entirely:**

- ❌ Run fixer → push → declare done without re-reviewing
  Fixing without re-reviewing = no review. Always run `--re-review` after fixes.

- ❌ Self-declare "the fix should address the issue" as completion
  Only a clean re-review (zero issues ≥ 50 confidence) is a valid exit signal.

- ❌ Re-review in the same conversation context
  Confirmation bias makes same-context re-review unreliable.
  Always use `--re-review` which dispatches fresh `task` sub-agents.

### Step 6.5 — Orchestrator Escalation (unattended recovery)

When the fixer loop exits with remaining issues (stall/cap/fail), the **orchestrator** (you, the main session) takes over BEFORE posting the PR comment:

1. **Read the remaining issues** — understand what the fixer couldn't solve
2. **Dispatch a deep-fix sub-agent** via Pi `task`:
   ```
   The automated fixer couldn't resolve these code-review issues after N cycles. You are the escalation path with FULL context and research capability.
   
   Remaining issues:
   <surviving issues JSON>
   
   PR branch: <branch>
   Affected files: <list>
   
   1. For EACH issue: research first — use web_search to understand the correct approach before touching code
   2. Checkout the PR branch
   3. Fix each issue with the correct, researched approach
   4. Commit with message: fix(code-review): deep escalation fix — PR #<N>
   5. Push
   6. Return FILES_WRITTEN and list which issues were resolved vs which remain unresolved with a brief explanation why
   ```
3. **If the deep-fix sub-agent resolves all issues** → re-review, then post "No issues found"
4. **If issues still remain** → THEN post the PR comment with the warning + remaining issues. These are the genuinely hard problems that need human judgment. Add a `### Requires Human Attention` section explaining what was tried and why each issue couldn't be auto-resolved.

**Pause only when:** a taxonomy-matching decision arises (human input taxonomy). Everything else proceeds unattended.

### Step 7 — Eligibility Re-check

Dispatch a sub-agent to re-check eligibility (same as Step 1).

### Step 8 — Post Comment

Use `gh pr comment` to post the review. **ALL surviving issues must be included** — even when the fixer loop exited with remaining issues.

**If fixer loop capped/stalled/failed (issues remain):**

```
⚠️ Auto-fix [stalled after N cycles | reached cycle cap | failed: <reason>] — M issues require human attention

### Code review

Found M issues:

1. <brief description> (<source>)
<link to file with full sha + line range>
...

🤖 Generated with [Pi](https://pi.dev)
<sub>- If this code review was useful, please react with 👍. Otherwise, react with 👎.</sub>
```

**If clean (no issues, or all fixed):**

```
### Code review

Found N issues:

1. <brief description> (<source>)

<link to file with full sha + line range>

2. ...

🤖 Generated with [Pi](https://pi.dev)

<sub>- If this code review was useful, please react with 👍. Otherwise, react with 👎.</sub>
```

Or if no issues:

```
### Code review

No issues found. Checked for bugs, guidance compliance, historical context, and prior PR comments.

🤖 Generated with [Pi](https://pi.dev)
```

**Link format:** `https://github.com/<owner>/<repo>/blob/<full sha>/<file>#L<start>-L<end>`. Require full SHA, provide 1 line of context before and after the issue.

### Step 9 — Logging (Supabase)

Best-effort logging — never block the workflow. For each issue ≥50 confidence:

```bash
JSON=$(python3 -c "
import json
from datetime import datetime, timezone
entry = {
  'ts': datetime.now(timezone.utc).isoformat(),
  'skill': 'code-review',
  'version': '2.0.0',
  'pr_number': <PR_NUMBER>,
  'pr_author': '<AUTHOR>',
  'file_path': '<FILE>',
  'check_type': '<TYPE>',
  'severity': '<SEVERITY>',
  'problem': '<≤200 char description>',
  'snippet': '<≤150 char code>',
  'confidence': <SCORE>
}
print(json.dumps(entry, ensure_ascii=False))
")
curl -s -o /dev/null -X POST \
  'https://axaeagulqhanatyoxrdv.supabase.co/rest/v1/code_review_errors' \
  -H 'apikey: <KEY>' \
  -H 'Authorization: Bearer <KEY>' \
  -H 'Content-Type: application/json' \
  -H 'Prefer: return=minimal' \
  -d "[$JSON]" \
  2>/dev/null \
|| (mkdir -p operations/logs && echo "$JSON" >> operations/logs/code-review-errors.jsonl)
true
```

**Check types:** `CLAUDE.md-adherence`, `comment-compliance`, `bug`, `historical-context`, `pr-comment-history`
**Severity:** `high` (90-100), `medium` (70-89), `low` (50-69)

## Standard-Tier Review (`--standard-tier`)

Runs 2 agents. Used when full review is disproportionate.

**Step 1-3:** Same as full review (eligibility, CLAUDE.md paths, summary).

**Step 4:** Launch only 2 parallel agents — Guidance Compliance + Bug Scan. Skip Git History and PR Comments.

**Step 5 onward:** Same as full review (scoring, filter, fixer, re-check, comment, logging). Append `(standard-tier review: guidance compliance + bug scan)` to comment header.

### Standard-Tier + Re-review

If `--re-review` with `--standard-tier`: identify fix commits (delta diff identification from Smart Re-Review Step A), scope agents to delta diff. If >4 files changed → fall back to full standard-tier. Append `(standard-tier re-review: fix-commits delta)`.

## Smart Re-Review (`--re-review`)

Targeted review on fix commits only. Skipped agents: Git History, PR Comments (static — won't have changed).

**Step A — Identify fix commits:** Sub-agent finds commits pushed after the most recent "### Code review" bot comment. Returns fix commit SHAs + distinct file count + combined delta diff.

**Step B — Scope check:** If >4 files changed → fall back to full review.

**Step C — CLAUDE.md paths:** Same as Step 2.

**Step D — Targeted review:** Launch 3 parallel agents on delta diff only:
- Guidance Compliance (delta diff)
- Bug Scan (delta diff)
- Guidance Compliance — code comments subset (delta diff, code comments only)

**Step E — Continue from Step 5:** Scoring, filter (skip fixer loop — `--re-review` disables it), re-check, comment, logging. Append `(re-review: fix-commits delta)` to comment header.

## False Positives to Ignore

- Pre-existing issues
- Something that looks like a bug but isn't
- Pedantic nitpicks a senior engineer wouldn't call out
- Issues a linter/typechecker/compiler would catch
- General code quality issues (test coverage, security, docs) unless explicitly required
- Issues silenced by lint ignore comments
- Changes likely intentional or directly related to the broader change
- Issues on lines the user did not modify

## Notes

- **Do NOT use Bash for reasoning or narration.** Only for commands that produce new information.
- **Prefer Read/Grep over Bash for file analysis.**
- Do not check build signal or attempt to build/typecheck.
- Use `gh` for GitHub interaction.
- Make a todo list first.
- Cite and link each bug with full SHA + line range.
