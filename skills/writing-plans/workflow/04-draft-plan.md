> **Step 4/5** | ← requires: `03-integration-surface.md` | → next: `05-review-handoff.md`

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
<!-- research-path: docs/epics/<slug>-research.md -->

# [Feature Name] Implementation Plan

> **For Pi:** Use `executing-plans` to implement this plan task-by-task.

**Goal:** [One sentence describing what this builds]

**Team:** [auto-populated from issue `**Team:**` → AGENT_SESSION_TEAM → fallback organisation-design-team]
**Role:** [auto-populated from AGENT_SESSION_ROLE, omit if unavailable]

**Architecture:** [2-3 sentences about approach]

### Pattern Research

[Embed the full `### Pattern Research` block produced by Step B — the three buckets with their canonical / competitor-variance / pitfall findings, plus the library docs preflight summary and any skip justifications. Or "Skipped — plan touches zero third-party deps" if applicable.]

### Integration Surface Map

[Embed the full Integration Surface Map produced by Step C — the `test-design` skill. Table of integration surfaces with test layer assignments, bug pattern flags, and checklist notes. Skip for Micro tier.]

### Journey Test Map

[Optional — skip if no user-facing journeys. Maps user goals to test cases so tests verify outcomes, not just code paths. Consumed by `test-writing` and `code-review`.]

```markdown
### Journey: [User Goal — what the user wants to achieve]
1. **Step:** [Action user takes] → **Acceptance:** [Expected outcome the user experiences] → **Test:** [test name / file]
2. **Step:** [Next action] → **Acceptance:** [Outcome] → **Test:** [test name / file]

### Failure Modes
- [Failure scenario] → **Expected behavior:** [How it should degrade] → **Test:** [test name]
```

**Tech Stack:** [Key technologies/libraries]

---
```

**The `<!-- research-path: ... -->` HTML comment** is a back-reference for `plan-review` and other downstream skills.

---

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Task Structure

````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

**Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

**Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## Remember
- Exact file paths always
- Complete code in plan (not "add validation")
- Exact commands with expected output
- Reference relevant skills with @ syntax
- DRY, YAGNI, TDD, frequent commits
- **New docs files in closed directories** must include a task step: "Register `<filename>` in `docs/teams/organisation-design-team/operations/00_index.md`" and run `npm run check:docs` to verify. Open directories are exempt. See `CLAUDE.md → Index enforcement at merge time`.
- **SQL functions implementing business logic** require a SQL-level test step — not just mocked TypeScript tests. The test step must use `npm run test:db` (pgTAP) or `execute_sql` via Supabase MCP.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Batching all 3+ framings into one perplexity call to save latency | Single batched call = one synthesis biased by one framing. Issue **separate** invocations per framing; parallel-safe |
| Silently skipping the gate when perplexity 401/402/429s | PAUSE and ask the user. Default to option (a) — never auto-pick (b) or (c) |
| Skipping the gate because the design seems clear | A clear approach is not a reason to skip |
| Re-firing the gate for libraries already verified upstream | Cite the prior finding — don't re-research what's already triangulated |
| Forgetting library docs preflight (Sub-step B.0) | Run library docs lookup BEFORE the gate |

## Tier-Scaled Execution

### Micro Tier

Skip plan file entirely. Instead, post an inline task description as an issue comment:

```bash
gh issue comment <ISSUE_NUMBER> --body "$(cat <<'EOF'
## Implementation

**Tier: micro** — No plan doc needed.

### Steps
1. [Step 1 — what to do]
2. [Step 2 — what to do]

### Files
- Modify: `exact/path/to/file`

Ready to implement. Run `commit-workflow` when done.
EOF
)"
```

No worktree, no TDD steps, no plan file saved.

**Auto-reclassification check:** If the step list has >5 items OR any step touches a migration/RLS/edge function → escalate to Standard or Complex.

### Standard Tier

Create a condensed plan file at `docs/plans/YYYY-MM-DD-<feature-name>.md`. No worktree required. Steps are descriptive — TDD not mandatory (but preferred for behavioral changes).

### Complex Tier

Full TDD plan doc with worktree isolation, bite-sized task steps, and complete test commands.

**Worktree (Complex tier only):** Create a dedicated worktree at the start before drafting:
```bash
git worktree add -b feature/<ISSUE_NUMBER>-<slug> ../<repo>-wt-<ISSUE_NUMBER>
cd ../<repo>-wt-<ISSUE_NUMBER>
```
