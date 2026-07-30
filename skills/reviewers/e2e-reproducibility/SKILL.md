---
name: e2e-reproducibility
description: Validates that described E2E tests can actually be executed — checks for concrete setup, clear assertions, and runnable conditions. Use when reviewing Detailed E2E substep output for Architecture + UX complexity axes. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — E2E Reproducibility

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

A test scenario description that reads well may be impossible to execute. This reviewer checks that every E2E test has concrete prerequisites, unambiguous steps, verifiable assertions, and no hidden dependencies that would prevent a fresh environment from running it.

## When Used

Dispatched by the fractal planning pipeline during the **Detailed E2E** substep when the epic's Architecture or UX complexity axis is rated medium or high.

## Inputs Required

- **Detailed E2E section** of the epic doc — all test scenario descriptions
- **Data Model section** — for understanding test data requirements
- **Architecture section** — for understanding system dependencies

## Checks to Run

### P0 — Must Fix

**E2R1 — Missing test data setup:**
- E2E test references specific data ("a user with 3 pending orders") but doesn't specify how that data is created
- Flag with the missing setup step

**E2R2 — Unverifiable assertion:**
- Test assertion is subjective or unmeasurable ("the page looks good", "performance is acceptable")
- Flag with "what specific, measurable condition defines success?"

### P1 — Should Fix

**E2R3 — External dependency not mocked:**
- Test depends on an external service (payment gateway, email, third-party API) without specifying how it's mocked/stubbed
- Flag with the external dependency

**E2R4 — Implicit auth state:**
- Test assumes a user is logged in without specifying the auth setup (which role, how session is created)
- Flag with the implicit assumption

**E2R5 — Non-deterministic step:**
- Test step relies on timing, random data, or system state that may vary between runs
- Flag with "what makes this deterministic?"

### P2 — Nice to Have

**E2R6 — Cleanup not specified:**
- Test creates data but doesn't specify cleanup — may pollute subsequent runs
- Flag with cleanup suggestion

**E2R7 — Parallel execution hazard:**
- Test manipulates shared state that would conflict with other tests running in parallel
- Flag with the shared resource

## Output Format

```
ISSUE #N
Dimension: E2E Reproducibility
Severity: P0 | P1 | P2
Location: [E2E scenario name, step N]
Problem: [what makes this test non-reproducible]
Fix: [what to specify or mock]
```

End with:
```
E2E REPRODUCIBILITY REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
E2E scenarios checked: [count]
Non-reproducible: [count]
Missing setups: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
