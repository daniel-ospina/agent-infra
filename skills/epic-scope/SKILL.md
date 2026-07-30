---
name: epic-scope
description: "Bounded skill for epic scoping. Takes strategy decision + research brief and produces scoped boundaries, high-level E2E test cases (BEFORE user journeys), and complexity ratings. Includes review gate with fresh-context reviewer. Invoked by epic-plan after research."
domain: planning
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

# Epic Scoping

**Announce at start:** "I'm using the epic-scope skill for boundary definition."

## Purpose

Bounded skill that defines what the epic includes and excludes. Takes the strategy decision (`epic-align`) and research brief (`epic-research`) and produces scoped boundaries with high-level E2E test cases — written BEFORE user journeys, not after.

## Workflow

### Step 1 — Scope Boundaries

Define what is IN and OUT of scope:

```markdown
## Scope Boundaries

### In Scope
- <concrete deliverable 1>
- <concrete deliverable 2>

### Out of Scope
- <explicitly excluded 1> — defer to <future epic/issue>
- <explicitly excluded 2> — defer to <future epic/issue>

### Boundary Rationale
<why these boundaries — what principle guides the cut>
```

### Step 2 — Complexity Ratings

Rate each complexity axis per the standard 3-tier system:

| Axis | Rating | Rationale |
|------|--------|-----------|
| UX | low/medium/high | <1 sentence> |
| Architecture | low/medium/high | <1 sentence> |
| Ontology | low/medium/high | <1 sentence> |
| Accessibility | low/medium/high | <1 sentence> |

### Step 3 — High-Level E2E Test Cases

**CRITICAL:** Write these BEFORE user journeys are drafted. High-level E2E tests describe what the app must do end-to-end — not how, not with specific UI elements.

Each test case format:

```markdown
### E2E-<N>: <short title>
**Given:** <precondition state>
**When:** <trigger action>
**Then:** <expected outcome 1>
**And:** <expected outcome 2>
```

Aim for 3-8 test cases that cover the full scope. These anchor the detailed E2E tests written later in `epic-plan`.

### Step 4 — Human Approval Gate

**HARD STOP.** Present the scope boundaries + high-level E2E tests:

```
## Epic Scope Ready for Review

**Scope:** <in/out summary>
**E2E test cases:** <count> drafted
**Complexity:** <ratings>

Review the scope boundaries and E2E test cases.
Reply "proceed" to continue to detailed planning, or give feedback.
```

Do NOT proceed until user confirms.

## Review Gate

After human approval, dispatch a fresh-context reviewer via `task` sub-agent:

```
Review this epic scope for:

1. BOUNDARY COMPLETENESS: Are in-scope items concrete and verifiable? Are out-of-scope items explicitly deferred?
2. E2E COVERAGE: Do the high-level test cases cover all in-scope items? Any gaps?
3. E2E TESTABILITY: Can each test case be verified without knowing UI details? (Should be behavioral, not presentational)
4. COMPLEXITY HONESTY: Are complexity ratings justified by the scope and research?

Return: NO ISSUES FOUND | ISSUES: <list>
```

Fix-loop until "NO ISSUES FOUND" or convergence; safety cap: 10 cycles.

## What Fails If You Skip

| Skip | Consequence |
|------|-------------|
| Scope boundaries | Feature creep — "while we're at it" additions without explicit decisions |
| High-level E2E tests | User journeys designed without testable outcomes — detailed tests discover missing flows too late |
| Human approval gate | User sees full epic plan and wants changes — rework cascades through all downstream phases |
| Complexity ratings | Downstream phases don't scale review gates correctly |

## Integration

**Called by:** `epic-plan` (pipeline step 3, after `epic-research`)
**Hands off to:** `epic-plan` (detailed planning phase)
**Input:** Strategy decision (`epic-align`) + research brief (`epic-research`)
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
