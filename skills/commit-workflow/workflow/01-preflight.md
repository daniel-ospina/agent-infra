> **Step 1/5** | → next: `02-commit-pr.md`

# Pre-flight Checks

## Git Lock Check

Before running any other pre-flight step, check for a stale lock file:

```bash
if [ -f .git/index.lock ]; then
  if pgrep -x git > /dev/null; then
    echo "❌ Another git process is running — cannot commit. Wait for it to finish."
    exit 1
  else
    rm .git/index.lock
    echo "Removed stale .git/index.lock"
  fi
fi
```

A stale lock (no live git process) is safe to remove. A live lock means another process owns the repo — wait.

## Doc Affiliation Check

Verify that changed docs have valid `subjects.team` front matter.

```bash
CHANGED_DOCS=$(git diff --cached --name-only --diff-filter=ACMR | grep '^docs/.*\.md$' || true)
if [ -n "$CHANGED_DOCS" ]; then
  echo "Checking document affiliation..."
  node scripts/check-doc-affiliation.cjs --files $CHANGED_DOCS || exit 1
fi
```

**Rules:**
- Triggers only on `docs/**/*.md` files (zero overhead for code-only commits)
- Uses `--diff-filter=ACMR` to catch creates, modifies, renames
- Blocks commit if validation fails (exit 1)
- Low-risk tier — skips typecheck/build for doc-only changes

## Pre-flight Verification (proportional — from proportional-gates v1.0.0)

### Language Detection

Detect the project language to route to correct checks:

```bash
# Check tracked files (not just staged) — a Python project might have zero .py staged
if git ls-files '*.py' | head -1 | grep -q .; then
  LANG=python
elif git ls-files '*.ts' '*.tsx' | head -1 | grep -q .; then
  LANG=typescript
else
  LANG=unknown
fi
```

### TypeScript / Supabase Stack (default)

**Match verification to change risk:**

| Risk | Typecheck | Build | Integration Tests | pgTAP |
|-------|-----------|-------|-------------------|-------|
| Low (docs, config, CSS, strings) | Skip | Skip | Skip | Skip |
| Medium (component/hook change) | Run if .ts/.tsx | Run if src/ | Run if integration surfaces | Run if migrations |

> **New module test gate:** Run `node scripts/check-untested-modules.cjs` for Medium+ changes. Blocks new `.ts`/`.tsx` files without matching test files. Exempts type-only files, config/constants, pure re-exports, and no-logic files. Use `--warn` for silent-run period.
| High (multi-file, DB, auth) | Always run | Always run | Always run | Always run |

> **Quality gates available on-demand (WARN only, do not block):** `npm run check:coverage-pruning`, `npm run check:arch:changed`, `npm run check:mutation` (nightly). See #6460-#6463.

### Python Stack

When `LANG=python`, use these equivalents:

| Risk | Syntax Check | Test | Integration Tests | Supabase |
|-------|-------------|------|-------------------|----------|
| Low (docs, config, strings) | Skip | Skip | Skip | Skip |
| Medium (single-file logic change) | `python3 -m py_compile` on changed .py | `python3 -m pytest` if tests/ exists | `python3 -m pytest` if integration markers | Skip |
| High (multi-file, DB, auth) | Always | Always | Always | Skip (unless supabase/ dir exists) |

**Python-specific notes:**
- Syntax check: `python3 -m py_compile` on each staged `.py` file (catches ImportErrors, syntax errors). Faster than full pytest for low-risk changes.
- Test run: `python3 -m pytest` if `tests/` or `test_*.py` files exist. No equivalent to `tsc --noEmit` — pytest is both syntax and behavior check.
- No pgTAP/replay-smoke equivalent — Python projects don't use Supabase migrations. Skip unless a `supabase/` directory is present (rare polyglot case).
- No build step — Python is interpreted. Skip.

**Skip rule:** If a check would not catch the change's failure mode, skip it. Note the skip. A reviewer validates the classification.

### Integration Tests

```bash
[ -f vitest.integration.config.ts ] && HAS_INTEGRATION=true || HAS_INTEGRATION=false
```

Run only when risk >= Medium AND integration surfaces are touched (DB queries, API calls, auth, shared state). Skip for UI-only, config, or doc changes. If run and tests fail: stop immediately and report.

### Typecheck

Run only when `.ts`/`.tsx` files changed. Skip for docs, config, CSS, or markdown-only changes.

```bash
npx tsc --noEmit
```

If fails: stop immediately and fix.

### Build

Run only when `src/` or config files changed. Skip for docs/skills/config-only changes. Build may require env vars — if it fails due to missing env vars and typecheck passed, skip build silently.

## pgTAP Tests (conditional)

Check if any **staged files** include migrations:

```bash
git diff --cached --name-only | grep -q 'supabase/migrations/' && HAS_COLUMN_DROP_MIGRATIONS=true || HAS_COLUMN_DROP_MIGRATIONS=false
```

If `HAS_COLUMN_DROP_MIGRATIONS=true` and `supabase` CLI is available:
- Announce: "Running pgTAP database tests..."
- Run: `npm run test:db` (or `supabase test db`)
- If tests fail: **stop immediately** and report. Do not commit.
- If `supabase` CLI is not available or `supabase start` is not running: skip with warning "pgTAP tests skipped — local Supabase not running"

If `HAS_COLUMN_DROP_MIGRATIONS=false`: skip silently.

> Supabase-specific gates (Replay Smoke, Column Drop Audit) are eldato-only — no `supabase/` dir in agent-infra; not applicable (issue #239).

## Skill Enforcement Audit (conditional)

Runs `scripts/ci/enforce-protocol-table.sh`. **Pass 1 is the live gate in agent-infra:** every dangerous-ops manifest skill (`enforcement/dangerous-ops.txt`) must resolve to a real `skills/<name>/SKILL.md` — a missing file is a silently broken enforcement gate. **Pass 2/3 (manifest ↔ AGENTS.md protocol table) are conditional:** they run only when AGENTS.md exists AND its protocol table is populated — in agent-infra the table is the template placeholder (and AGENTS.md is untracked/generated), so Pass 2/3 skip-with-note; they activate in consumer repos with populated tables (issue #239).

**Condition:** Only when **staged files** include changes under `skills/`, `enforcement/`, or `AGENTS.md`.

```bash
git diff --cached --name-only --no-renames | grep -qE '^(skills/|enforcement/|AGENTS\.md)' && HAS_SKILL_CHANGES=true || HAS_SKILL_CHANGES=false
```

- If `HAS_SKILL_CHANGES=true`:
  - Announce: "Running Skill Enforcement Audit..."
  - Run: `bash scripts/ci/enforce-protocol-table.sh`
  - If it fails: **stop immediately** and report. Do not commit.
- If `HAS_SKILL_CHANGES=false`: skip silently.

> Script ported into agent-infra in #239 (from eldato @ 49afc61f, blob fb4c5357). eldato's `enforce-skills.yml` was never ported; agent-infra has no CI workflow running this script — drift coverage is solely this pre-flight trigger on `skills/|enforcement/|AGENTS.md` commits (issue #239 D5).

## Issue Detection

Detect the linked issue **before committing** (avoids stalling mid-sequence):

1. **Branch name** — look for pattern `feat/123-*`, `fix/123-*`, `chore/123-*` → extract issue number
2. **Commit message scan** — search staged diff / recent commits for `fixes #N`, `closes #N`, `resolves #N`
3. **Ask the user** — if neither resolves: "Which issue does this work close? (or 'none')"

Store as `ISSUE_NUMBER` for use in subsequent steps.

## Branch Detection

```
Already on a feature branch (not main/master)?
  → Run the merged-branch guard below FIRST. If safe, commit here. No branch creation needed.

On main/master + ISSUE_NUMBER resolved?
  → Auto-create: git fetch origin main --quiet && git checkout -b feat/issue-{N}-{slug} origin/main
  → (slug = 3-4 word summary of the work, kebab-case)

On main/master + no ISSUE_NUMBER?
  → Ask: "What should I name the new branch?"
```

### Merged-Branch Guard (runs when already on a feature branch)

Before committing on an existing feature branch, verify it hasn't already been merged. Committing unrelated changes (e.g. skill doc fixes) onto a branch whose PR was merged can cause those changes to be silently absorbed into a squash-merge — polluting the merge with unintended content. This happened with PR #2167 where skill documentation edits were accidentally squash-merged into a pizza/sushi content PR.

```bash
BRANCH=$(git branch --show-current)

# Check if this branch has an open PR (not merged, not closed)
PR_STATE=$(gh pr view --json state --jq '.state' 2>/dev/null || echo "no-pr")

# Check if this branch's commits are already on main (merged)
git fetch origin main --quiet
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
  ALREADY_MERGED=true
else
  ALREADY_MERGED=false
fi
```

| Situation | Action |
|-----------|--------|
| `PR_STATE = "MERGED"` or `ALREADY_MERGED = true` | **BLOCK.** Output: "⚠️ Branch `BRANCH` has already been merged to main. Creating a new branch for this work instead." Then auto-create a new branch off `origin/main`. |
| `PR_STATE = "CLOSED"` | **WARN.** Output: "⚠️ Branch `BRANCH` has a closed (unmerged) PR. Proceeding, but consider whether this work belongs on a new branch." Then proceed. |
| `PR_STATE = "OPEN"` | **Proceed.** The branch has an active PR — changes pushed here will update it. |
| `PR_STATE = "no-pr"` and `ALREADY_MERGED = false` | **Proceed.** Fresh feature branch with no PR yet. |

## Pre-PR Freshness Check (#178/#181)

Runs AFTER the Merged-Branch Guard and BEFORE Tier Detection (the guard already
fetches and may redirect to a fresh branch — reconciling before its verdict
wastes work). Reconcile the branch with the origin default so stale checkouts
never ship:

```bash
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
git fetch origin "$DEFAULT_BRANCH" --quiet
BEHIND=$(git rev-list --count HEAD.."origin/$DEFAULT_BRANCH" 2>/dev/null || echo 0)
```

| State | Action |
|---|---|
| `BEHIND = 0` | Silent — already current. |
| `BEHIND > 0` + clean tree | `git -c commit.gpgsign=false pull --rebase origin "$DEFAULT_BRANCH"`, then RE-RUN the affected pre-flight regression tests. If the branch was previously pushed and the post-rebase push is rejected as non-fast-forward → `git push --force-with-lease`. |
| `BEHIND > 0` + dirty tree | **WARN**: "Branch is N behind origin/<default> — commit or stash first, then `git -c commit.gpgsign=false pull --rebase origin <default>`." NEVER autostash (conflict-unsafe unattended). |

Notes: `commit.gpgsign=false` is process-scoped and prevents headless pinentry
hangs during rebase (fleet ships squash-merged; research-verified). Condition 5
in 04-merge-deploy.md still governs overlap at merge time; repos with strict
up-to-date protection additionally use Stale-Merge Recovery there.

## Tier Detection

Check the linked issue for a `complexity:*` label:

```bash
# Only if ISSUE_NUMBER is resolved (not 'none')
gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep '^complexity:'
```

- `complexity:micro` → **TIER = Micro**
- `complexity:standard` → **TIER = Standard**
- `complexity:complex` → **TIER = Complex**
- No label found or `ISSUE_NUMBER = 'none'` → **TIER = unknown** (classify from diff in Step 1.5 / `02-commit-pr.md`)

Store as `TIER` for subsequent steps. Export as `AGENT_ISSUE_COMPLEXITY` for downstream extension gates (review-enforcer proportional blocking):

```bash
export AGENT_ISSUE_COMPLEXITY=$TIER
echo "$TIER" > /tmp/agent-issue-complexity
```

### Micro Tier Auto-Detection & Gate Behavior

When `TIER = Micro` or auto-detected (1 file, <20 added lines, no migrations):

| Gate | Micro Behavior |
|------|---------------|
| Review-enforcer | **KEPT** — 1 task sub-agent dispatch required before git ops |
| Verification-gate (VGATE) | **SKIPPED** — single reviewer dispatch is sufficient |
| Lint/Typecheck | **KEPT** — runs in pre-commit hooks, zero agent overhead |
| Code review (Step 3) | **SKIPPED** — per commit-workflow/03-code-review.md |

**Rationale:** A single reviewer sub-agent catches stupid agent mistakes without the 3+ minute per-file VGATE overhead. For a 2-line fix, a 10-second "CLEAN" review is proportional. Zero gates would let obvious bugs through.

## Wiring-Gap Check (canary-fix PRs only)

If `ISSUE_NUMBER` is resolved and not `'none'`, check for the `ci-failure` label and "typecheck-canary" in the issue title. These signal a canary-fix PR that might only address the type error without fixing the runtime gap.

```bash
ISSUE_TITLE=$(gh issue view $ISSUE_NUMBER --json title --jq '.title')
IS_CI_FAILURE=$(gh issue view $ISSUE_NUMBER --json labels --jq '.labels[].name' | grep -q '^ci-failure$' && echo true || echo false)
IS_CANARY=$(echo "$ISSUE_TITLE" | grep -qi 'typecheck-canary' && echo true || echo false)

if [ "$IS_CI_FAILURE" = "true" ] && [ "$IS_CANARY" = "true" ]; then
  echo "🔍 Canary-fix PR detected — running wiring-gap check"
  WIRING_CHECK=true
else
  WIRING_CHECK=false
fi
```

If `WIRING_CHECK=true`, before committing:

1. Identify which field/column was missing — from the `tsc` error: "Property 'X' does not exist on type 'Y'"
2. Search every data-fetching path that constructs an object of type `Y` — `.select()` calls, view queries, construction/mapping functions, API response handlers, ORM queries
3. Verify the missing field `X` is included in ALL of those paths
4. If the field appears in a component but not in the corresponding query/construction code: **BLOCK.** The fix is incomplete — the feature will compile but silently fail at runtime.
5. If the field is wired through all layers: proceed.

This guard exists because #4327/#4328 demonstrated a type error fix can mask a wiring gap: `tripadvisor_url` existed in the DB and types but wasn't fetched by `useDeals.ts`, producing a silent `undefined`.

## Pi Extension Gates (mandatory — not tier-gated)

These two checks are enforced by Pi extensions and apply to every commit regardless of risk tier.

### Review Enforcer Gate

The `review-enforcer` extension blocks git operations unless at least one `task` sub-agent was dispatched this session.

```bash
# This gate fires ON the git commit/push command itself — not as a separate check.
# To satisfy it: dispatch a reviewer sub-agent BEFORE running git commit.
# Even a trivial one-line review counts.
```

**How to satisfy:**
1. Before `git commit`, dispatch a `task` sub-agent to review your changes
2. The reviewer must return a result (even "NO ISSUES FOUND")
3. The gate counts task dispatches — 1 is enough

**Failure:** "No reviewers were dispatched in this session before the git operation."  
**Bypass:** `AGENT_SKIP_REVIEW_GATE=1` (emergency only)

### Verification Gate

The `verification-gate` extension blocks `git commit` unless every staged file has been verified by a `[VGATE]` sub-agent.

**How to satisfy:**
```bash
# Dispatch a verifier sub-agent:
task(prompt='[VGATE] verify files: <list staged files>. Classification: <UI|backend|doc>. Project root: <repo root>.', ...)
```

**Format requirements (CRITICAL):**
- Prompt MUST say `verify files:` (plural) — `verify file:` (singular) will silently fail
- Response MUST include `PASS` on its own line, OR valid JSON: `{"status": "PASS", "failures": [], "verified_files": [{"path": "...", "hash": "..."}]}`
- `**VERIFIED**` is NOT enough — the gate regex looks for `PASS`

**Gotchas:**
- If staged files change after verification, hashes won't match — re-verify
- The gate extracts file paths from the prompt, not the response — make sure paths are correct
- `AGENT_SKIP_VGATE=1` at session start disables this gate entirely (`AGENT_ALLOW_MAIN_EDITS=1` no longer does — #7470)

---

### Test-Review Hash Backstop Gate

**Purpose:** Ensure every test file has passed test-review before commit. Complements VGATE (which verifies file content quality) by verifying test correctness. Catches any code path that bypassed the test-writing → test-review mandatory gate.

**When:** Standard+Complex tier commits where staged files include `.ts`, `.tsx`, `.py`, `.sql`, `.js`, or `.jsx`.

**Skip:** Micro tier commits, or commits with no matching file extensions.

**Mechanism:**

```bash
# Skip for micro tier
ISSUE_BODY=$(gh issue view <N> --json body -q '.body')
IS_COMPLEXITY_MICRO=$(echo "$ISSUE_BODY" | grep -q 'complexity:micro' && echo true || echo false)
[ "$IS_COMPLEXITY_MICRO" = "true" ] && exit 0

# Check for testable files
STAGED=$(git diff --cached --name-only)
HAS_TESTABLE=$(echo "$STAGED" | grep -qE '\.(ts|tsx|py|sql|js|jsx)$' && echo true || echo false)
[ "$HAS_TESTABLE" != "true" ] && exit 0

# Check each test file for test-review hash
for FILE in $(echo "$STAGED" | grep -E '\.(test|spec|e2e)\.(ts|tsx)$|\.pg$|\.py$'); do
  # Skip deleted files
  git diff --cached --diff-filter=D -- "$FILE" | grep -q . && continue
  
  ABS_PATH=$(realpath "$FILE" 2>/dev/null || readlink -f "$FILE" 2>/dev/null || echo "$FILE")
  if command -v sha256sum >/dev/null 2>&1; then
    FILE_HASH=$(echo -n "$ABS_PATH" | sha256sum | cut -d' ' -f1)
  else
    FILE_HASH=$(echo -n "$ABS_PATH" | shasum -a 256 | cut -d' ' -f1)
  fi
  HASH_FILE="$HOME/.pi/agent/test-review/${FILE_HASH}.json"
  
  if [ ! -f "$HASH_FILE" ]; then
    echo "⛔ BLOCKED: test-review never completed for $FILE"
    echo "   Run test-writing → test-review before committing."
    exit 1
  fi
  
  STATUS=$(python3 -c "import json; print(json.load(open('$HASH_FILE'))['status'])" 2>/dev/null || echo "ABSENT")
  
  case "$STATUS" in
    CLEAN)
      echo "✅ $FILE — test-review: CLEAN"
      ;;
    CAPPED)
      ISSUES=$(python3 -c "import json; d=json.load(open('$HASH_FILE')); print('; '.join(i['description'][:80] for i in d.get('capped_issues',[])))" 2>/dev/null || echo "unknown")
      echo "⚠️ $FILE — test-review: CAPPED ($ISSUES)"
      ;;
    *)
      echo "⛔ BLOCKED: invalid hash status '$STATUS' for $FILE"
      exit 1
      ;;
  esac
done

# TTL cleanup: remove hashes older than 30 days
find "$HOME/.pi/agent/test-review/" -name '*.json' -mtime +30 -delete 2>/dev/null || true

# Orphan cleanup: remove hashes where test file no longer exists
for HF in "$HOME/.pi/agent/test-review/"*.json; do
  [ ! -f "$HF" ] && continue
  FP=$(python3 -c "import json; print(json.load(open('$HF')).get('test_file_path',''))" 2>/dev/null || true)
  [ -n "$FP" ] && [ ! -f "$FP" ] && rm -f "$HF"
done
```

**Tri-state verdict:**
- **ABSENT** (no hash file) → **BLOCK** — test-review was never completed
- **CAPPED** (hash exists, status=CAPPED) → **WARN** — proceed with documented issues
- **CLEAN** (hash exists, status=CLEAN) → proceed

**Post-commit cleanup:** After successful commit, delete consumed hash files for CLEAN-status files in this commit.
