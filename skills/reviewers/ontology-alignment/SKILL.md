---
name: ontology-alignment
description: Detects vocabulary drift and semantic inconsistency in epic terminology. Use when reviewing Data Model substep output for Ontology complexity axis. Returns structured ISSUE blocks or NO ISSUES FOUND.
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Ontology Alignment

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

Ensures the epic uses the canonical controlled vocabulary consistently. Catches terminology drift — the same concept named differently across the epic, or a new term introduced when a canonical one already exists.

## When Used

Dispatched by the fractal planning pipeline during the **Data Model** substep when the epic's Ontology complexity axis is rated medium or high.

## Inputs Required

- **Full epic doc** — all sections (terminology drift spans sections)
- **Canonical controlled vocabulary:** `docs/teams/organisation-design-team/data/controlled_vocabulary.md`
- **Canonical ontology:** `docs/teams/organisation-design-team/data/ONTOLOGY.md`

## Checks to Run

### P0 — Must Fix

**OA1 — Canonical term overridden:**
- Epic uses a different name for a concept that already has a canonical term in the controlled vocabulary
- Flag with epic term → canonical term

**OA2 — Same concept, different names:**
- Same entity/action named differently in different sections of the epic
- E.g., "Customer" in Data Model but "User" in User Journeys
- Flag with all variants and location references

### P1 — Should Fix

**OA3 — New concept without definition:**
- Epic introduces a new entity/term without defining it or explaining why the canonical vocabulary is insufficient
- Flag with the undefined term

**OA4 — Semantic overload:**
- Same term used for different concepts in different sections
- E.g., "Order" meaning purchase in one section and sort-order in another
- Flag with both meanings and locations

### P2 — Nice to Have

**OA5 — Verb/noun inconsistency:**
- Actions described with inconsistent verbs (e.g., "remove" vs "delete" vs "archive" for the same operation)
- Flag with suggested canonical verb

**OA6 — Plural/singular drift:**
- Entity names used inconsistently as singular or plural (e.g., "Deal" vs "Deals" for the same table)
- Flag with suggested canonical form

## Output Format

```
ISSUE #N
Dimension: Ontology Alignment
Severity: P0 | P1 | P2
Location: [section name, paragraph reference]
Problem: [what term drifts from what canonical form]
Fix: [what term to use instead]
```

End with:
```
ONTOLOGY ALIGNMENT REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Terminology variants: [count]
New undefined terms: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
