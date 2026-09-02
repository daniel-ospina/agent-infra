---
disable-model-invocation: true
name: e2e-coverage
description: Verifies that all high-level user scenarios are fleshed out into detailed end-to-end test descriptions. Use when reviewing Detailed E2E substep output for Architecture + UX complexity axes. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — E2E Coverage

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks E2E TEST scenarios map to journeys. For journey-level role/state coverage, see `reviewers/ux-coverage`.

Maps every high-level scenario from the epic's User Journeys to detailed E2E test cases. Ensures no journey is left untested, every critical path has coverage, and edge cases identified in earlier substeps are reflected in the E2E descriptions.

## When Used

Dispatched by the fractal planning pipeline during the **Detailed E2E** substep when the epic's Architecture or UX complexity axis is rated medium or high.

## Inputs Required

- **Detailed E2E section** of the epic doc — the test scenario descriptions
- **User Journeys section** — for the high-level scenarios that should be covered
- **Workflows section** — for step-by-step flows to map to tests
- **Acceptance Criteria** from the epic — for pass/fail conditions

## Checks to Run

### P0 — Must Fix

**E2E1 — Untested user journey:**
- A user journey from the User Journeys section has zero corresponding E2E test scenarios
- Flag with the journey name

**E2E2 — Missing critical path:**
- The primary happy-path flow for a core feature has no E2E test
- Flag with the feature name

### P1 — Should Fix

**E2E3 — Edge case not tested:**
- An edge case identified in earlier substeps (UX Realism, Integration) has no E2E coverage
- Flag with the edge case reference

**E2E4 — State transition gap:**
- Key state transition (empty → loading → error → retry → success) not covered by any E2E test
- Flag with the missing transition

**E2E5 — Cross-role scenario missing:**
- Scenario involving multiple roles interacting (identified in User Journeys) has no E2E test
- Flag with the scenario and involved roles

### P2 — Should Fix (blocks merge)

**E2E6 — Performance/load scenario:**
- No E2E test for behavior under load, concurrent access, or slow network (if relevant)
- Flag with suggestion

**E2E7 — Accessibility E2E:**
- No E2E test covering keyboard navigation, screen reader flow, or reduced-motion path
- Flag with suggestion

## Output Format

```
ISSUE #N
Dimension: E2E Coverage
Severity: P0 | P1 | P2
Location: [user journey name or scenario reference]
Problem: [what's not covered by E2E tests]
Fix: [what test scenario to add]
```

End with:
```
E2E COVERAGE REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Journeys with E2E coverage: [X/Y]
Total E2E scenarios: [count]
Coverage gaps: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
