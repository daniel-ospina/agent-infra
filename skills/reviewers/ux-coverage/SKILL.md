---
name: ux-coverage
description: Verifies that all user roles and UI states are covered in epic user journeys. Use when reviewing User Journeys substep output for UX complexity axis. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — UX Coverage

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks user JOURNEY descriptions for role/state completeness. For E2E TEST scenario coverage, see `reviewers/e2e-coverage`.

Checks that every user role identified in the epic has its journey described, and that every journey covers all relevant UI states (loading, empty, error, edge cases, success).

## When Used

Dispatched by the fractal planning pipeline during the **User Journeys** substep when the epic's UX complexity axis is rated medium or high.

## Inputs Required

- **User Journeys section** of the epic doc — the full journey descriptions, role definitions, and state transitions
- **Epic problem statement** — for cross-referencing which roles are in scope

## Checks to Run

### P0 — Must Fix

**UXC1 — Missing role:**
- Every role mentioned in the epic's problem statement or scope MUST have at least one journey
- Flag any role with zero journey entries

**UXC2 — Missing critical state:**
- Every journey MUST address: loading, empty, error, and success states
- Flag any journey missing one of these four states

### P1 — Should Fix

**UXC3 — Edge case gaps:**
- Common edge cases for the domain (timeouts, concurrent actions, offline) should be addressed where relevant
- Flag edge cases that would break the flow if encountered

**UXC4 — State transition clarity:**
- Transitions between states should be explicit (what triggers empty → loading? error → retry?)
- Flag ambiguous or implicit transitions

### P2 — Should Fix (blocks merge)

**UXC5 — Accessibility states:**
- Focus management, screen reader announcements, reduced-motion preferences
- Flag journeys that would benefit from explicit accessibility notes

**UXC6 — Cross-role intersections:**
- Where two roles interact (e.g., admin approves user action), both perspectives should be covered
- Flag intersections covered from only one side

## Output Format

```
ISSUE #N
Dimension: UX Coverage
Severity: P0 | P1 | P2
Location: [journey name or section reference]
Problem: [what's missing or unclear]
Fix: [what to add or clarify]
```

End with:
```
UX COVERAGE REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Roles covered: [X/Y]
States per journey: [min/avg/max]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
