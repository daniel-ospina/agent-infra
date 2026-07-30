---
name: debug-workflow
description: Pipeline-gated debugging workflow. Classifies bug complexity, routes through issue-workflow to task-workflow or project-workflow, then applies systematic root-cause methodology. Use when encountering any bug, test failure, or unexpected behavior.
domain: engineering
type: Workflow
status: live
tags: [pipeline, debugging, root-cause, workflow]
created: 2026-07-07
updated: 2026-07-07
steps:
  - name: classify_and_route
    type: skill
    gate: auto
    produces: [bug_classification]
  - name: pipeline_execute
    type: skill
    gate: auto
    requires: [classify_and_route]
    produces: [issue_routed]
  - name: root_cause_investigation
    type: skill
    gate: auto
    requires: [pipeline_execute]
    produces: [root_cause]
  - name: pattern_analysis
    type: skill
    gate: auto
    requires: [root_cause_investigation]
    produces: [patterns]
  - name: hypothesis_and_testing
    type: skill
    gate: auto
    requires: [pattern_analysis]
    produces: [tested_hypothesis]
  - name: fix_and_verify
    type: skill
    gate: verifier
    requires: [hypothesis_and_testing]
    produces: [verified_fix]
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

**Verifier gate:** dispatches AI reviewers. Pipeline auto-advances when clean.

# Debug Workflow

Pipeline-gated debugging — classifies bug complexity and routes through issue-workflow.

> **Ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md` — canonical entity classes, work vocabulary, domain taxonomy.

## Pipeline Integration

<HARD-GATE>
**No code inspection until the bug is classified and routed through issue-workflow.** Do NOT open files, read stack traces, or form hypotheses before Step 1.
</HARD-GATE>

### Step 1 — Classify + Route

Classify bug complexity and route through `issue-workflow`:

```bash
# Create a bug issue
gh issue create --title "Bug: <symptom>" --label "bug,complexity:<tier>" --body "..."

# Route through issue-workflow — it detects Level and dispatches
# issue-workflow → task-workflow (simple) or project-workflow (medium/complex)
```

| Bug complexity | Tier | Pipeline | Gates |
|---------------|------|----------|-------|
| Simple — 1 file, obvious from stack trace | `complexity:micro` | `task-workflow` (inline) | Typecheck + targeted test |
| Medium — 2-5 files, unclear cause | `complexity:standard` | `project-workflow` | AI review + test-review, 3-5 queries |
| Complex — multi-component, unknown pattern | `complexity:complex` | `project-workflow` | Full research + AI review + test-review |

**O/I/T for every bug issue:**
- **Objective:** Identify and fix root cause of `<symptom>`
- **Indicator:** Root cause identified, fix applied, tests pass, symptom resolved
- **Target:** 0 reproduction steps trigger the bug

### Step 2 — Pipeline executes

The workflow skill runs its stages:
- **Align** — inherited or quick check (is this worth fixing?)
- **Research** — proportional depth (light for simple, medium/deep for complex)
- **Scope** — acceptance criteria inline (bug repro steps = scope)
- **Plan** — 1-3 sentence approach or proportional plan
- **Implement** — THIS skill's 4-phase methodology (below)
- **Verify** — typecheck + targeted test (simple) or full test-review (complex)

## Debugging Methodology (Implement Phase)

The 4-phase process runs during the Implement stage. Root cause before fixes.

### Phase 1: Root Cause Investigation

1. **Read error messages completely** — don't skip past errors. Stack traces, line numbers, error codes often contain the exact solution.
2. **Reproduce consistently** — exact steps, reliable trigger. If not reproducible, gather more data.
3. **Check recent changes** — git diff, recent commits, new dependencies, config changes.
4. **Trace data flow** — where does the bad value originate? Trace up the call stack to the source. Fix at source, not at symptom.
5. **External research** (when codebase analysis is insufficient) — 1-2 targeted Perplexity queries for library behavior, version-specific bugs, API quirks. One search that surfaces a known gotcha is faster than 3 wrong fixes.

### Phase 2: Pattern Analysis

1. Find working examples in the same codebase
2. Compare working vs broken — list every difference
3. Understand dependencies — what components, config, assumptions?

### Phase 3: Hypothesis and Testing

1. Form a single hypothesis: "X is the root cause because Y"
2. Test minimally — smallest possible change, one variable
3. Verify before continuing — did it work? If not, form a NEW hypothesis. Don't pile on more fixes.

### Phase 4: Fix and Verify

1. **Create failing test** — simplest reproduction. Automated if possible.
2. **Implement single fix** — address root cause, one change. No "while I'm here" improvements.
3. **Verify** — test passes? No other tests broken? Symptom resolved?
4. **If 3+ fixes failed** — STOP. Question the architecture. This is a wrong pattern, not a wrong fix. Discuss before attempting more.

## Red Flags

If you catch yourself thinking:
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Skip the test, I'll manually verify"
- "It's probably X, let me fix that"
- "One more fix attempt" (after 2+ failures)
- Proposing solutions before tracing data flow

**ALL of these mean: STOP. Return to Phase 1.**

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Simple bug, don't need process" | Simple bugs have root causes too. Process is fast for simple bugs. |
| "Emergency, no time" | Systematic debugging is FASTER than guess-and-check thrashing. |
| "I'll write test after confirming fix works" | Untested fixes don't stick. Test first proves it. |
| "Multiple fixes at once saves time" | Can't isolate what worked. Causes new bugs. |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause. |

## References

- `../issue-workflow/SKILL.md` — Entry-point router
- `../task-workflow/SKILL.md` — Lightweight pipeline (simple bugs)
- `../project-workflow/SKILL.md` — Proportional pipeline (medium/complex bugs)
- `../verification-before-completion/SKILL.md` — Verify fix worked
- `docs/teams/organisation-design-team/data/ONTOLOGY.md` — Pipeline stages

---
> Continue following the workflow as mandated by this skill. Do not skip steps.
