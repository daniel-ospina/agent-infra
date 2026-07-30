---
name: improvement-opportunities
description: Identifies what could be better in the epic — missed optimizations, simplifications, or better approaches. Use during Coherence Review for all complexity axes. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Improvement Opportunities

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

The final coherence pass that looks beyond correctness to find opportunities for improvement: simplifications, better patterns, missed optimizations, and alignment with the principle of "good > easy." This reviewer is constructive, not adversarial — it flags things that could be better, not things that are broken.

## When Used

Dispatched by the fractal planning pipeline during the **Coherence Review** phase, after all substeps are complete. Applies regardless of complexity axis ratings.

## Inputs Required

- **Full epic doc** — all substep outputs
- **Existing codebase patterns** — for identifying opportunities to reuse rather than reinvent
- **ADR and design docs** — for alignment with established decisions

## Checks to Run

### P0 — Must Fix

> P0 is rare for improvement opportunities — this reviewer is primarily P1/P2. But flag as P0 if:

**IO1 — Active harm:**
- The current approach will cause measurable harm (performance degradation, user confusion, maintenance burden) that a known better approach would avoid
- Flag with the harm and the alternative

### P1 — Should Fix

**IO2 — Missed simplification:**
- A section of the epic is more complex than it needs to be — a simpler approach exists that achieves the same goal
- Flag with "what if instead we..."

**IO3 — Reinvention of existing pattern:**
- Epic proposes a new pattern for something the codebase already solves
- Flag with the existing pattern reference (file path, component name)

**IO4 — Better technology choice:**
- Epic chooses a technology when a better alternative exists (stdlib, existing dependency, native platform feature)
- Flag with "why X when Y already does this?"

### P2 — Nice to Have

**IO5 — Sequencing optimization:**
- Substeps or implementation phases could be reordered for faster value delivery or risk reduction
- Flag with suggested reorder

**IO6 — Missing delight:**
- Opportunity to add something that would meaningfully improve the user experience at low implementation cost
- Flag with the opportunity

**IO7 — Documentation/ADR opportunity:**
- A decision made in the epic would benefit from being recorded as an ADR for future reference
- Flag with the decision

## Output Format

```
ISSUE #N
Dimension: Improvement Opportunity
Severity: P0 | P1 | P2
Location: [substep or section reference]
Problem: [what could be better]
Fix: [suggested improvement]
```

End with:
```
IMPROVEMENT OPPORTUNITIES REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Simplifications suggested: [count]
Pattern reuse opportunities: [count]
Other improvements: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
