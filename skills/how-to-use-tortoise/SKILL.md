---
name: how-to-use-tortoise
description: Create points, operators, mitigations, NANDs, supersede, delete, and annotate on the Tortoise graph. Use when asked to write to the Tortoise graph — creating points, operators, mitigations, NAND edges, superseding points, deleting, or annotating.
domain: capability
type: Workflow
status: live
tags: [tortoise, graph, epistemology, knowledge-graph, operations]
summary: "Safe Tortoise graph write operations — teaches edge semantics (IMPL vs NAND), mitigation ranges, supersession cleanup, sourceKind taxonomy, and annotation rules."
created: 2026-07-14
updated: 2026-07-31
allowed-tools: read write edit bash grep find
---

> ⛔ **This skill MUST be read in full before any Tortoise graph write.** Skipping corrupts the graph.

# How to Use Tortoise

Safe graph write operations for the Tortoise probabilistic inference graph.

## Hard Gate

**Any graph write** (create_point, create_operator, mitigate_operator, supersede_point, delete_point, annotate_point, invalidate_point) **MUST** go through this skill. Bypassing it risks:
- EP weights nuked by batch-connected mitigations
- Orphaned NAND edges with no cleanup
- Superseded operators with active edges still propagating
- Label-based content instead of structural claims

## Edge Types

| Type | Semantics | Use When |
|------|-----------|----------|
| **IMPL** | A implies/supports B | Evidence supports a claim |
| **NAND** | A contradicts B | Evidence conflicts with a claim |

## Mitigation Ranges

Mitigations reduce claim confidence. Range: **0.10–0.50**.

- 0.10: Minor caveat (claim is mostly true)
- 0.30: Significant limitation
- 0.50: Major counter-evidence (claim is substantially weakened)

Never use <0.10 (negligible) or >0.50 (would invert the claim — use NAND instead).

## SourceKind Taxonomy

| Tier | Label | Description |
|------|-------|-------------|
| T0 | Direct Observation | First-hand empirical evidence |
| T1 | Primary Source | Original document, raw data |
| T2 | Secondary Source | Analysis, interpretation of primary sources |
| T3 | Tertiary Source | Synthesis, summaries, encyclopedias |
| T4 | Speculative | Hypothetical, unverified claims |

## Supersession

When superseding a point:
1. Create the new point with updated content
2. Call `supersede_point(old_id, new_id)` — this cleans up edges
3. Verify old point's edges are properly transferred

## Annotation Rules

- Annotations describe WHY an edge exists (rationale, not label)
- Use sentence-case, be specific
- Never annotate with just a label (e.g., "evidence" — say what evidence)

## Common Mistakes

| Mistake | Consequence | Correct |
|---------|-------------|---------|
| Batch-connecting mitigations | EP weights cascade-nuked | Connect mitigations one at a time, verify each |
| NAND without checking existing IMPL | Orphaned contradiction | Check for existing IMPL edges before adding NAND |
| Superseding without edge cleanup | Stale edges from old point still propagate | Always call supersede_point, never manually move edges |
| Label-based annotation | Unreadable graph | Write rationale sentences, not keywords |

## Pre-Write Checklist

- [ ] Have I read the target point's current edges?
- [ ] Am I using the correct edge type (IMPL vs NAND)?
- [ ] If mitigation: is the value in 0.10–0.50 range?
- [ ] If NAND: have I checked for existing IMPL edges?
- [ ] If superseding: will I call supersede_point (not manually move edges)?
- [ ] Are my annotations sentence-case rationales, not labels?

---
> After writing, verify with tortoise-verify-chain to ensure graph integrity.
