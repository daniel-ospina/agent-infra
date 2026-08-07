---
name: contract-completeness
description: Validates that all component interfaces in the epic have complete input/output definitions. Use when reviewing Interfaces substep output for Architecture complexity axis. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Contract Completeness

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks individual interface CONTRACTS (inputs, outputs, types). For system-level integration surface identification, see `reviewers/integration`.

Checks every interface defined in the epic's Interfaces section for completeness: all inputs specified with types, all outputs (including error states) defined, and all edge cases covered. An incomplete contract causes downstream implementation ambiguity.

## When Used

Dispatched by the fractal planning pipeline during the **Interfaces** substep when the epic's Architecture complexity axis is rated medium or high.

## Inputs Required

- **Interfaces section** of the epic doc — all API contracts, function signatures, type definitions, event schemas
- **Data Model section** — for cross-referencing types
- **Architecture section** — for interface context

## Checks to Run

### P0 — Must Fix

**CC1 — Missing input type:**
- Interface defines an input but doesn't specify its type (string, number, object shape, enum values)
- Flag with the untyped input

**CC2 — Missing output definition:**
- Interface describes an action but doesn't specify what it returns (success shape, error shape)
- Flag with the undefined output

**CC3 — Reference to undefined type:**
- Interface references a type that isn't defined in the Data Model or Interfaces sections
- Flag with the dangling reference

### P1 — Should Fix

**CC4 — Missing error states:**
- Interface defines success output but no error/edge-case outputs
- Flag with missing error types (validation error, auth error, not found, server error)

**CC5 — Implicit auth/authorization:**
- Interface doesn't specify what auth context is required (which role, what permissions)
- Flag with the unspecified auth requirement

**CC6 — Ambiguous optionality:**
- Input/output field whose required/optional status is unclear
- Flag with "is this required or optional?"

### P2 — Should Fix (blocks merge)

**CC7 — Missing rate limit / quota info:**
- Interface that likely has rate limits but doesn't specify them
- Flag with suggestion

**CC8 — Versioning / deprecation notes:**
- Interface that modifies an existing contract without versioning or deprecation strategy
- Flag with suggestion

**CC9 — Pagination / cursor support:**
- List endpoint without pagination, cursor, or limit parameters specified
- Flag with "how are large result sets handled?"

## Output Format

```
ISSUE #N
Dimension: Contract Completeness
Severity: P0 | P1 | P2
Location: [interface name, parameter/field name]
Problem: [what's missing from the contract]
Fix: [what to specify]
```

End with:
```
CONTRACT COMPLETENESS REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Interfaces checked: [count]
Incomplete contracts: [count]
Missing type definitions: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
