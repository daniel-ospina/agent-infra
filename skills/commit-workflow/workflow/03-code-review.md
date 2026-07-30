> **Step 3/5** | ← requires: `02-commit-pr.md` | → next: `04-merge-deploy.md`

# Code Review Gate


### Step 3.6 — Complexity Ratings Extraction (P0-3)

Before dispatching code-review agents, extract domain complexity ratings from the linked issue. These determine which conditional agents (Agents #5-#8) to dispatch.

```bash
ISSUE_NUMBER=$(gh pr view <PR_NUMBER> --json closingIssuesReferences --jq '.closingIssuesReferences[0].number')
if [ -n "$ISSUE_NUMBER" ]; then
  SCOPING_PLAN=$(gh issue view $ISSUE_NUMBER --json comments --jq '.comments[] | select(.body | contains("<!-- issue-scoping:")) | .body' | tail -1)
  if [ -n "$SCOPING_PLAN" ]; then
    UX_RATING=$(echo "$SCOPING_PLAN" | awk -F'|' '/^\| *UX/ {gsub(/ /,""); print $3}' | tr '[:upper:]' '[:lower:]' | xargs)
    ARCH_RATING=$(echo "$SCOPING_PLAN" | awk -F'|' '/^\| *Architecture/ {gsub(/ /,""); print $3}' | tr '[:upper:]' '[:lower:]' | xargs)
    ONTOLOGY_RATING=$(echo "$SCOPING_PLAN" | awk -F'|' '/^\| *Ontology/ {gsub(/ /,""); print $3}' | tr '[:upper:]' '[:lower:]' | xargs)
  fi
fi

# Default: empty = skip domain reviewers
: ${UX_RATING:=""}
: ${ARCH_RATING:=""}
: ${ONTOLOGY_RATING:=""}
```

Pass these ratings to code-review Step 4 dispatch logic. When all empty, only the 4 safety-net agents run.

## Step 2 — Code-Review Gate

**Micro tier: skip entirely.** Pre-flight checks (typecheck, tests) are the safety net. Proceed directly to Step 3 (`04-merge-deploy.md`).

**Standard tier:** Invoke `code-review` with the full 5-agent review + NVIDIA pattern scan (Agent #6):

The Standard tier fix-loop follows the same structure as Complex. Specifically:

```
iteration = 0

LOOP:
  Use the Skill tool to invoke `code-review`:
  - First pass (iteration = 0): args = `<PR_NUMBER> --nvidia-review`
  - Subsequent passes (iteration ≥ 1): args = `<PR_NUMBER> --nvidia-review --re-review`

  If NO issues (confidence ≥ 50):
    → Promote draft to ready-for-review:
      gh pr ready <PR_NUMBER>
    → Exit loop, proceed to Step 3

  If issues found:
    iteration += 1
    If iteration >= 5 AND same issues recur: pause and ask user
    Invoke `superpowers:receiving-code-review`, fix issues, commit, push
    → Continue LOOP
```

**Complex tier (and default when TIER is unknown):** Run the full 5-agent review + NVIDIA pattern scan (Agent #6):

```
iteration = 0

LOOP:
  Use the Skill tool to invoke `code-review`:
  - First pass (iteration = 0): args = `<PR_NUMBER> --nvidia-review`
  - Subsequent passes (iteration ≥ 1): args = `<PR_NUMBER> --nvidia-review --re-review`
  (The hook fires on `gh pr merge` only — fix-loop iterations require this explicit Skill tool invocation.)

  If NO issues (confidence ≥ 50):
    → Promote draft to ready-for-review:
      gh pr ready <PR_NUMBER>
    → Exit loop, proceed to Step 3

  If issues found:
    iteration += 1

    If iteration >= 5 AND same issues recur:
      → Pause: "Code-review found recurring issues after 5 attempts.
                 [Show issues]. How would you like to proceed?"
      → Wait for user

    Invoke `superpowers:receiving-code-review` on the review feedback. Apply the External Reviewer track — verify each issue is technically correct before implementing; push back if a suggestion is wrong for this codebase.

    Fix all reported issues
    git add <changed files>
    git commit -m "fix: address code-review feedback (round {iteration})"
    git push
    → Continue LOOP
```

## Step 2.5 — Migration Review Gate

**Skip if** the PR diff contains no files matching `supabase/migrations/*.sql`.

Dispatch a subagent with explicit instructions to review **only the migration SQL files** in the PR diff. Use the same model as the current session — omit the `model` parameter. Do NOT specify a different model. The subagent prompt must include:

1. The migration file contents (read each `supabase/migrations/*.sql` file in the diff)
2. The Supabase project ID (from `supabase/config.toml` or environment) so it can query production schema via `mcp__claude_ai_Supabase__execute_sql`
3. The review checklist below

### Migration Review Checklist

The subagent must check each migration file against:

| # | Check | How to verify |
|---|-------|---------------|
| 1 | **Safety** — `IF EXISTS`/`IF NOT EXISTS` guards on CREATE/DROP; destructive DDL flagged | Grep for unguarded `CREATE TABLE`, `DROP`, `TRUNCATE`, `DELETE FROM` |
| 2 | **Idempotency** — survives partial apply or re-run | Check for `ADD COLUMN` without `IF NOT EXISTS`, `CREATE INDEX` without `IF NOT EXISTS` |
| 3 | **Schema match** — function signatures, column types match production | Query `pg_proc` for function args, `information_schema.columns` for columns via `execute_sql` |
| 4 | **Performance** — lock-heavy operations have `SET lock_timeout` | Flag `ALTER TABLE` on known high-traffic tables without `lock_timeout` |
| 5 | **Security** — `SECURITY DEFINER` has `SET search_path = public`; new tables have `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` | Pattern match in SQL |
| 6 | **Conventions** — timestamp later than latest existing migration | Compare against `ls supabase/migrations/ | sort | tail -1` |
| 7 | **Overload count** — for any `CREATE OR REPLACE FUNCTION`, verify production currently has exactly one overload (pre-existing overloads cause 42725 on deploy); also verify the migration includes `DROP FUNCTION IF EXISTS` when changing parameters | `SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = '<name>'` must equal 1; migration SQL must contain DROP when signature changes |

### Subagent Return Format

The subagent must return a structured result:

```
STATUS: CLEAN | HAS_ISSUES
ISSUES (if any):
  - [ERROR] <file>: <description>
  - [WARNING] <file>: <description>
```

Only `[ERROR]` items trigger the fix-loop. `[WARNING]` items are logged but do not block merge.

### Fix-Loop

```
iteration = 0

LOOP:
  Dispatch migration-review subagent

  If STATUS = CLEAN (no ERROR items):
    → Proceed to Step 3

  If ERROR items found:
    iteration += 1
    If iteration >= 5 AND same issues recur:
      → Pause: "Migration review found recurring issues after 5 attempts.
                 [Show issues]. How would you like to proceed?"
      → Wait for user

    Fix all ERROR items
    git add <changed files>
    git commit -m "fix: address migration review feedback (round {iteration})"
    git push
    → Continue LOOP
```
