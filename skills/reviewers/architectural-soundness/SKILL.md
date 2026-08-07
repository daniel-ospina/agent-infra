---
name: architectural-soundness
description: Validates that the epic's architecture aligns with the overall system design and epic goals. Use when reviewing Architecture substep output for Architecture complexity axis. Reuses patterns from plan-review architectural-soundness reviewer. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Architectural Soundness

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks architecture-specific alignment (ADR contradictions, SPOF, technology choices). For cross-dimensional risk completeness, see `reviewers/risk-completeness`.

Checks that the epic's proposed architecture aligns with the parent epic's architecture (if nested), respects existing system boundaries, and doesn't silently diverge from established design decisions. Reuses the epic-alignment review dimension from `plan-review/references/reviewers/architectural-soundness.md`.

## When Used

Dispatched by the fractal planning pipeline during the **Architecture** substep when the epic's Architecture complexity axis is rated medium or high.

## Inputs Required

- **Architecture section** of the epic doc — proposed system design, component interactions
- **Parent epic doc** (if this is a child epic) — for architectural alignment
- **Existing architecture docs:** ADRs in `docs/teams/*/decisions/`, system design docs
- **Data Model section** of the epic — for cross-referencing architectural implications

## Checks to Run

### P0 — Must Fix

**AS1 — Epic alignment divergence (from plan-review architectural-soundness):**
- Does the architecture's data model match the epic's stated goals?
- Does the migration approach match the epic's phases?
- Does the architecture respect the epic's component boundaries?
- Are there any silent divergences from the parent epic architecture?

**AS2 — Contradicts existing ADR:**
- Proposed architecture contradicts a documented Architectural Decision Record
- Flag with ADR reference and the contradiction

### P1 — Should Fix

**AS3 — Missing architectural concern:**
- Common architectural concern not addressed: scalability, observability, security, deployment
- Flag the missing dimension

**AS4 — Over-engineering:**
- Architecture proposes complexity beyond what the epic scope requires
- Flag with YAGNI suggestion — what could be simplified

**AS5 — Under-specification:**
- Architecture hand-waves a critical component ("a queue", "a cache", "a message bus") without specifying which technology or why
- Flag the unspecified component

### P2 — Should Fix (blocks merge)

**AS6 — Technology choice without rationale:**
- Specific technology named without explaining why it's the right choice for this context
- Flag with "why X over Y?"

**AS7 — Single point of failure:**
- Architecture depends on a single service/component without redundancy or fallback
- Flag with the SPOF

## Output Format

```
ISSUE #N
Dimension: Architectural Soundness
Severity: P0 | P1 | P2
Location: [architecture section or diagram reference]
Problem: [what's architecturally unsound]
Fix: [what to change or clarify]
```

End with:
```
ARCHITECTURAL SOUNDNESS REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
ADR contradictions: [count]
Missing concerns: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
