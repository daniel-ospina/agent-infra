---
disable-model-invocation: true
name: ux-realism
description: Validates that described workflows can actually function given real-world constraints. Use when reviewing Workflows substep output for UX complexity axis. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — UX Realism

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

Stress-tests workflow descriptions against real-world constraints: network latency, partial data, concurrent users, device limitations, and human error. A workflow that reads cleanly on paper may break under these conditions.

## When Used

Dispatched by the fractal planning pipeline during the **Workflows** substep when the epic's UX complexity axis is rated medium or high.

## Inputs Required

- **Workflows section** of the epic doc — the step-by-step workflow descriptions
- **User Journeys section** — for context on what triggers each workflow
- **Technical constraints** from the epic (if any: target devices, offline requirements, API latency expectations)

## Checks to Run

### P0 — Must Fix

**UXR1 — Impossible sequence:**
- Workflow step depends on data or state that doesn't exist yet at that point in the flow
- E.g., "user reviews order summary" before "user adds items to cart"
- Flag with exact step numbers

**UXR2 — Missing prerequisite:**
- Workflow assumes a precondition that isn't established (authentication, data loaded, permission granted)
- Flag the missing prerequisite

### P1 — Should Fix

**UXR3 — Network dependency without fallback:**
- Step that requires network (API call, file upload) but no loading/error/offline state described
- Flag with the specific step

**UXR4 — Concurrency blind spot:**
- Workflow assumes single-user, single-session behavior when the feature involves shared state
- Flag race condition scenarios (two users editing same resource, simultaneous submissions)

**UXR5 — Data volume assumption:**
- Workflow describes interactions that break at realistic data volumes (e.g., "scroll through all items" with 10,000 items)
- Flag with suggested mitigation (pagination, search, filter)

### P2 — Should Fix (blocks merge)

**UXR6 — Device constraint:**
- Interaction that's impractical on target devices (e.g., drag-and-drop on mobile, hover on touch)
- Flag with device context

**UXR7 — Recovery path:**
- Workflow interrupted mid-sequence — no recovery or resume path described
- Flag with suggestion (save draft, resume later, idempotent operations)

## Output Format

```
ISSUE #N
Dimension: UX Realism
Severity: P0 | P1 | P2
Location: [workflow name, step N]
Problem: [what breaks under real-world conditions]
Fix: [what to change or add]
```

End with:
```
UX REALISM REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Workflows checked: [count]
Constraint violations: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
