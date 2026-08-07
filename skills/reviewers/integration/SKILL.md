---
name: integration
description: Validates that component boundaries in the epic architecture are clean and all integration surfaces are accounted for. Use when reviewing Architecture substep output for Architecture complexity axis. Reuses patterns from plan-review integration reviewer. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Integration

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks system-level integration surfaces and consumer identification. For individual interface contract completeness, see `reviewer/contract-completeness`.

Checks that the epic's architecture defines clean component boundaries, identifies all integration surfaces, and accounts for every system that touches or is touched by the change. Reuses the integration review dimension from `plan-review/references/reviewers/integration.md`.

## When Used

Dispatched by the fractal planning pipeline during the **Architecture** substep when the epic's Architecture complexity axis is rated medium or high.

## Inputs Required

- **Architecture section** of the epic doc — component diagram, system boundaries, data flow
- **Full epic doc** — for cross-referencing interfaces mentioned in other sections
- **Codebase context:** key files referenced in the architecture (existing APIs, edge functions, shared types)

## Checks to Run

### P0 — Must Fix

**INT1 — Missing system in boundary diagram:**
- Architecture diagram or description omits a system that the epic's user journeys or data model depend on
- Flag the missing system with the section that references it

**INT2 — Unidentified API consumer:**
- New or changed API endpoint without enumerating all consumers
- Flag with the endpoint and missing consumer identification

### P1 — Should Fix

**INT3 — Interface & integration gaps (from plan-review integration reviewer):**
- Does the architecture identify ALL systems that touch or are touched by this change?
- API contracts: if an API shape changes, are all consumers accounted for?
- Shared types: if TypeScript types change, are all importers identified?
- Edge functions: if DB schema changes, are edge functions that query those tables updated?
- SSR pages: if data shape changes, are server-rendered pages accounted for?
- RLS policies: if table access patterns change, are RLS policies addressed?
- Frontend consumers: if API responses change, are React components identified?

**INT4 — Failure mode gaps (from plan-review integration reviewer):**
- Are failure modes addressed for each integration point?
- Are auth boundaries checked (who can access what)?
- Are concurrency issues considered?
- Are empty/null states handled?

### P2 — Should Fix (blocks merge)

**INT5 — Error propagation:**
- How do errors propagate across component boundaries? Is there a consistent error-handling strategy?
- Flag inconsistent or missing error handling

**INT6 — Versioning strategy:**
- If API contracts change, is there a migration/versioning strategy for consumers?
- Flag missing versioning considerations

### Test Coverage (from plan-review integration reviewer)

**INT7 — Missing integration test coverage:**
- Does every integration surface have a corresponding test?
- SQL business logic: does it require SQL-level tests (pgTAP), not just mocked TS?
- Are edge cases covered by tests?
- Do tests verify behavior, not implementation details?

## Output Format

```
ISSUE #N
Dimension: Integration
Severity: P0 | P1 | P2
Location: [architecture diagram reference or section name]
Problem: [what integration surface is missing or unclear]
Fix: [what to add or clarify]
```

End with:
```
INTEGRATION REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Systems identified: [count]
Integration surfaces: [count]
Missing consumers: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
