---
disable-model-invocation: true
name: ux-consistency
description: Detects contradictory or inconsistent user flows across epic journeys. Use when reviewing User Journeys substep output for UX complexity axis. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — UX Consistency

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

Cross-references all user journeys in the epic to find contradictions: the same action producing different results in different journeys, conflicting terminology, divergent navigation patterns, or inconsistent permission behavior.

## When Used

Dispatched by the fractal planning pipeline during the **User Journeys** substep when the epic's UX complexity axis is rated medium or high.

## Inputs Required

- **User Journeys section** of the epic doc — all journey descriptions for all roles
- **Epic scope / problem statement** — for baseline expected behavior

## Checks to Run

### P0 — Must Fix

**UXN1 — Contradictory behavior:**
- Same user action described with different outcomes in different journeys (e.g., "clicking Cancel saves a draft" in journey A but "clicking Cancel discards" in journey B)
- Flag with both journey references

**UXN2 — Terminology drift:**
- Same concept named differently across journeys (e.g., "Project" vs "Workspace", "Submit" vs "Send" vs "Publish")
- Flag with all variant names and suggest canonical term

### P1 — Should Fix

**UXN3 — Divergent navigation:**
- Same destination reached via different paths without explanation (e.g., settings accessible from sidebar in one journey, from profile dropdown in another)
- Flag with both paths

**UXN4 — Permission inconsistency:**
- Same role has different capabilities in different journeys (e.g., role X can delete in journey A but only archive in journey B)
- Flag with role + both permissions

### P2 — Should Fix (blocks merge)

**UXN5 — Pattern drift from codebase:**
- Journey describes a UX pattern that differs from existing patterns in the live app (check codebase for precedent)
- Flag with existing component/file reference

**UXN6 — Tone/voice inconsistency:**
- Copy or messaging tone shifts between journeys (e.g., formal in one, casual in another for the same audience)
- Flag with examples

## Output Format

```
ISSUE #N
Dimension: UX Consistency
Severity: P0 | P1 | P2
Location: [journey A] vs [journey B]
Problem: [what contradicts]
Fix: [resolution — which behavior is correct, or what to reconcile]
```

End with:
```
UX CONSISTENCY REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Terminology variants found: [count]
Contradictory behaviors: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
