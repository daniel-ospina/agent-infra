---
disable-model-invocation: true
name: schema-correctness
description: Validates that the epic data model matches the canonical entity model and database schema. Use when reviewing Data Model substep output for Ontology complexity axis. Returns structured ISSUE blocks or NO ISSUES FOUND.
subjects.team: organisation-design-team
allowed-tools: read bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Reviewer — Schema Correctness

> **Skill type:** Modular — independently invocable, reusable across Workflows.
> **Continuity:** none — fresh session per invocation, no state carried between calls.

Cross-references the epic's proposed data model against the canonical entity model (`ONTOLOGY_SPEC_v4.0.md`) and the live database schema. Catches column drift, missing constraints, type mismatches, and RLS gaps.

## When Used

Dispatched by the fractal planning pipeline during the **Data Model** substep when the epic's Ontology complexity axis is rated medium or high.

## Inputs Required

- **Data Model section** of the epic doc — proposed tables, columns, relationships, constraints
- **Canonical entity model:** `docs/teams/eldato-app-team/domains (S1)/data/ONTOLOGY_SPEC_v4.0.md` (eldato repo — fetch: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`)
- **Current DB schema:** query `information_schema.columns` via Supabase or read `src/integrations/supabase/types.ts`

## Checks to Run

### P0 — Must Fix

**SC1 — Entity model mismatch:**
- Proposed table/column does not match the canonical entity definition in ONTOLOGY_SPEC
- Flag with entity name + diverging attribute

**SC2 — Missing foreign key:**
- Relationship described in the data model without a corresponding FK constraint
- Flag with source table.column → target table

**SC3 — Type mismatch with live schema:**
- Proposed column type differs from existing column type for the same logical attribute
- Flag with both types

### P1 — Should Fix

**SC4 — Missing RLS policy:**
- New table without a corresponding RLS policy described
- Flag with table name

**SC5 — Index gap:**
- Column used in JOIN/WHERE in the epic's query patterns but no index proposed
- Flag with column + query pattern

**SC6 — Soft-delete inconsistency:**
- New table doesn't follow the project's soft-delete convention (if one exists — check existing tables)
- Flag with convention reference

### P2 — Should Fix (blocks merge)

**SC7 — Naming convention drift:**
- Column or table name diverges from codebase convention (snake_case, singular table names, etc.)
- Flag with suggested rename

**SC8 — Enum vs reference table:**
- Proposed enum where a reference table would be more maintainable (or vice versa)
- Flag with rationale

**SC9 — Migration timestamp ordering:**
- Proposed migration timestamp is not later than the latest existing migration
- Flag with `check:migrations` convention reference

## Output Format

```
ISSUE #N
Dimension: Schema Correctness
Severity: P0 | P1 | P2
Location: [table.column or relationship reference]
Problem: [what doesn't match]
Fix: [what to change]
```

End with:
```
SCHEMA CORRECTNESS REVIEW SUMMARY
P0 issues: [count]
P1 issues: [count]
P2 issues: [count]
Entities checked: [count]
Schema divergences: [count]
```

If no issues found, return: NO ISSUES FOUND
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
