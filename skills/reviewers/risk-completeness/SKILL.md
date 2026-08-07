---
name: risk-completeness
description: Verifies that all risks are identified and have mitigation strategies in the epic. Use during Coherence Review for all complexity axes. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Risk Completeness

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.
> **Boundary:** Checks risk completeness across ALL dimensions (technical, UX, data, timeline, dependency). For architecture-specific risks (SPOF, ADR contradictions), see `reviewers/architectural-soundness`.

Audits the epic for unidentified risks across technical, UX, data, timeline, and dependency dimensions. Also verifies that every identified risk has a concrete mitigation strategy, not just a hand-wave acknowledgment.

## When Used

Dispatched by the fractal planning pipeline during the **Coherence Review** phase, after all substeps are complete. Applies regardless of complexity axis ratings.

## Inputs Required

- **Full epic doc** — all substep outputs
- **Risks section** (if already populated) — for checking mitigation completeness
- **Architecture section** — for technical risk context
- **Data Model section** — for data risk context

## Checks to Run

### P0 — Must Fix

**RC1 — Unmitigated high-impact risk:**
- A risk identified in any substep (implicitly or explicitly) has no corresponding mitigation in the Risks section
- Flag with the risk description and where it was identified

**RC2 — Catastrophic scenario not considered:**
- The epic's scope has an obvious catastrophic failure mode (data loss, security breach, revenue impact) not addressed
- Flag with the scenario

### P1 — Should Fix

**RC3 — Missing risk dimension:**
- Entire risk category absent: technical, UX, data, timeline, dependency, security, operational
- Flag with the missing dimension and what risks to consider

**RC4 — Vague mitigation:**
- Risk has a mitigation that's too vague to execute ("monitor closely", "handle errors gracefully")
- Flag with "what specific action, by whom, when?"

**RC5 — Dependency risk not surfaced:**
- Epic depends on another team, system, or external service — no risk assessment
- Flag with the dependency

### P2 — Should Fix (blocks merge)

**RC6 — Risk probability/impact not estimated:**
- Risk listed without likelihood or severity assessment
- Flag with suggestion to add low/medium/high ratings

**RC7 — Rollback strategy missing:**
- Epic involves a migration or schema change without a rollback plan
- Flag with suggestion

## Output Format

```
ISSUE #N
Dimension: Risk Completeness
Severity: P0 | P1 | P2
Location: [substep or section reference]
Problem: [what risk is missing or insufficiently mitigated]
Fix: [what risk to add or how to strengthen mitigation]
```

End with:
```
RISK COMPLETENESS REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Risks identified: [count]
Unmitigated risks: [count]
Missing risk dimensions: [list]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
