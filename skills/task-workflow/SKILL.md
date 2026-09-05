---
name: task-workflow
description: Lightweight fractal pipeline for micro tasks (complexity:micro). Routes through all 6 stages inline — no Bounded skill dispatch. Agent applies the phase discipline directly. Standard/complex tasks route to task-workflow-standard.
type: Workflow
domain: capability
subjects.team: organisation-design-team
status: live
tags: [pipeline, task, planning, fractal, orchestrator, lightweight]
summary: "Workflow skill for micro-issues — all 6 pipeline stages applied inline with no sub-skill dispatch. Canonical micro pipeline (task-workflow-micro merged here)."
created: 2026-07-07
updated: 2026-08-08
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
version: 1.1.0
---

> ⛔ **This skill MUST be read in full — not skimmed.** Lightweight ≠ skipped. All phases must be followed.

# Task Workflow (Micro)

Routes a task (micro issue) through all 6 pipeline stages. Lightweight — the agent applies the phase discipline inline. No Bounded sub-skill dispatch. No separate workflow files.

## Branch Isolation (runs BEFORE Phase 1)

> ⛔ **Every issue gets its own branch.** This prevents the 2026-08-06 incident where #74's work committed onto #73's branch.

Before any work begins, verify branch isolation:

```bash
ISSUE_NUMBER="<N>"              # from the issue being worked
SLUG="<kebab-slug>"             # brief slug from issue title
EXPECTED_BRANCH="feat/${ISSUE_NUMBER}-${SLUG}"
CURRENT=$(git branch --show-current)

[ "$CURRENT" = "$EXPECTED_BRANCH" ] && exit 0   # already on correct branch

if [ "$CURRENT" = "main" ] || [ "$CURRENT" = "master" ]; then
  git checkout -b "$EXPECTED_BRANCH"
  exit 0
fi

# Detached HEAD? ABORT — no branch to verify
if [ -z "$CURRENT" ]; then
  echo "⛔ ABORT: Detached HEAD. Checkout main first: git checkout main && git checkout -b $EXPECTED_BRANCH"
  exit 1
fi

# ABORT: on a DIFFERENT issue's branch (boundary match prevents #76 matching #760)
if ! echo "$CURRENT" | grep -qE "(^|/)$ISSUE_NUMBER(-|\$)"; then
  echo "⛔ ABORT: On branch $CURRENT (different issue). Switch to main first, then create $EXPECTED_BRANCH."
  exit 1
fi
```

> When dispatching parallel subagents, each must get its own worktree — see `skills/issue-workflow/SKILL.md` Branch+Worktree Isolation section for the full pattern.

## Pipeline (all phases, lightweight — no orchestrator workflow files)

> Routed via `Level: task` + `complexity:micro` in issue-creation fractal fields (see `issue-workflow` dispatch). Standard/complex tasks route to `task-workflow-standard` — this skill is the **micro pipeline only**.

1. **Align** — Inherited from parent Epic/Project. Only required if standalone.
2. **Research** — Quick codebase check: read affected files, existing patterns. **Proportional external trigger (issue #231 D11):** after the codebase check, if the task touches **third-party deps or a novel pattern with no in-repo precedent**, fire **1–2 external queries** (canonical usage + pitfalls — `web_search`/perplexity_search, never gated models) and record as an inline `> Research note:` line in the task plan comment with a findings-date + per-framing provenance (canonical / pitfalls + source). Budget mode (`EXECUTION_INTENT=Budget`): skip external queries (codebase-read only). Mechanical trigger inputs: affected-file import lines naming third-party modules (e.g. `import ... from '^[a-z@]'`), or the issue's `**Research:**` field if present — not the `**Dependencies:**` field (that is sibling-issue ordering). No demonstrated gap → no queries; do NOT self-judge novelty loosely — the trigger is dependency/novelty evidence, not opinion.
3. **Scope** — Inline in issue body: acceptance criteria = scope.
4. **Plan** — Inline: 1-3 sentence implementation approach in plan comment.
5. **Implement** — The fix.
6. **Verify** — Typecheck + targeted test. Verification skill's philosophy applies (test real thing, not just code).

## Align Inheritance

When the task is linked to an Epic or Project (issue body has parent reference):
- The Align gate is **skipped** — the parent's Align Decision covers this task

When the task is standalone:
- Quick Align check: is this worth doing? (one sentence, no formal gate)

## Lightweight Rules

| Phase | Epic Depth | Task Depth |
|-------|-----------|------------|
| Align | Full adversarial + Eisenhower | Inherited or quick check |
| Research | Full research brief | Codebase check + proportional external trigger (1–2 queries only on third-party deps / novel pattern; Budget: skip) |
| Scope | Scope brief + E2E | Acceptance criteria inline |
| Plan | 8 substeps + review gates | 1-3 sentence approach |
| Implement | TDD tasks | If NEW module or NEW public functions → invoke test-writing (Red phase first). Then direct fix. |
| Verify | Full pre/post-deploy | NEW automated tests for NEW code + typecheck. See Verify Gate Checklist. |

> All phases followed. No sub-skill dispatch — agent applies the discipline inline.

---
> Continue following the workflow as mandated by this skill. Do not skip steps.

### Verify Gate Checklist

Before claiming a task done, the Verify phase MUST pass:

- [ ] **New module?** → `test_<module>.py` must exist with >=1 behavioral assertion per public function
- [ ] **New public method/function?** → >=1 test per method asserting user-visible outcome
- [ ] **Typecheck passes** (0 errors)
- [ ] **All tests pass** (0 failures)
- [ ] **Existing tests still pass** (no regressions)
- [ ] **Modified DB trigger/function/RLS?** → run existing pgTAP tests for that function (`npm run test:db`). Check `supabase/tests/` for matching pgTAP files. If no pgTAP tests exist for the modified function → WARN (file follow-up issue for pgTAP coverage).

If any check fails, the task is NOT done. Return to Implement phase.
