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
- Criteria with no provenance — untethered from the customer needs they serve

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

## Two Dimensions of Critique: Truth vs Weight

When a claim faces challenge, you have two tools. They address different things:

| | NAND | mitigatedBy |
|---|------|-------------|
| **What it says** | "This claim is FALSE" | "This claim is TRUE but matters LESS than it seems" |
| **Dimension** | Correctness | Relevance |
| **Effect on EP** | Contradiction propagates through graph | Confidence reduction on the edge |
| **Applies to** | The argument Point directly | The operator (IMPL connection) between argument and what it supports |

**Example:** "A1: Provider cannot read content" supports Option A via IMPL.

- **NAND:** "Metadata reveals topics, so the provider CAN infer some content." → This says A1 is categorically wrong. NAND the A1 point.
- **mitigatedBy (0.20):** "Metadata is lossy, like email subjects — visible but not the full content." → This says A1 is true, but the privacy claim is weaker than it sounds. Mitigate the IMPL operator.

**Rule of thumb:** If you're saying the argument is wrong → NAND. If you're saying it's overstated → mitigatedBy.

## SourceKind Taxonomy

| Tier | Label | Description |
|------|-------|-------------|
| T0 | Direct Observation | First-hand empirical evidence |
| T1 | Primary Source | Original document, raw data |
| T2 | Secondary Source | Analysis, interpretation of primary sources |
| T3 | Tertiary Source | Synthesis, summaries, encyclopedias |
| T4 | Speculative | Hypothetical, unverified claims |

## Decision Provenance: Tracing Criteria to Customer Needs

A decision's criteria shouldn't float. They should trace back to who needs them and why. The chain flows from customer-facing needs down to architecture choices:

```
[domain concepts from expansion packs] → Criterion → Argument → Option
```

Each link is an IMPL connection. The specific pointKinds in the chain depend on the expansion packs loaded — product-strategy packs provide customer segments and use cases, PM packs provide requirements, core provides decisions and options. Load the packs, check their registered kinds and relations, and wire the chain accordingly.

The chain is auditable in both directions:
- **Downward:** "which customer need does this criterion serve?" → traverse IMPL up
- **Upward:** "which decisions does this requirement drive?" → traverse IMPL down

An agent auditing an ADR can walk the full chain: understand not just what was decided, but why the criteria exist, who they serve, and whether the decision holds up if those customer needs change.

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

# Searching the Graph

Tortoise supports two search modes for different use cases.

## Two Search Modes

| Mode | Tool | What It Does | When to Use |
|------|------|-------------|-------------|
| **Full-scan** | `tortoise_query` (context only, no query) | Returns ALL Points in a subgraph | Graph review, finding weak spots, integrity checks, duplicate detection |
| **Best-match** | `tortoise_search` (with query string) | Returns top-N Points ranked by RRF fusion | Agent context retrieval, entity resolution, "what does the graph believe about X?" |

**Key rule:** Full-scan mode **never filters by confidence** — low-confidence points are exactly what reviewers need to see. Best-match mode annotates confidence but defaults to no filter.

## Which Tool to Use

| Tool | Use When |
|------|----------|
| `tortoise_search` | You have a text query and want ranked, relevant results. Returns RRF-fused results from FTS + vector + structural indexes with full EP breakdown. |
| `tortoise_query` | You want to filter by kind/context without text search. Use `text` param for hybrid search. Supports `order_by` (relevance/confidence) and `min_confidence`. |
| `tortoise_suggest_entry_points` | You need to resolve an entity name from natural language (e.g., "what entities relate to pricing?"). Uses hybrid search for semantic matching. |

## EP Breakdown Fields

Every search result includes an `ep` object with:

| Field | Meaning | Range |
|-------|---------|-------|
| `confidence_mean` | EP Beta posterior mean — how confident the graph is | 0.0–1.0 |
| `evidence.impl_count` | Number of IMPL (supporting) edges | 0+ |
| `evidence.nand_count` | Number of NAND (contradicting) edges | 0+ |
| `evidence.total` | Total edge count (impl + nand) | 0+ |
| `contention` | Ratio of NAND to total — how disputed the claim is | 0.0–1.0 |

**Interpreting confidence:**
- 0.50 mean + low total evidence (total < 5) = **uncertainty** — not enough data yet
- 0.50 mean + high total evidence (total > 10) + high contention (> 0.3) = **disagreement** — strong opposing views
- 0.85 mean + high total evidence = **settled** — strong supporting evidence

## Ordering and Filtering

- `order_by="relevance"` (default): Results ranked by RRF fusion score — best semantic + keyword match
- `order_by="confidence"`: Results sorted by EP confidence_mean descending — highest-confidence claims first
- `min_confidence=0.5`: Only return Points with confidence_mean ≥ 0.5 (default: 0.0 = no filter)

**When to filter by confidence:** Use when you need settled claims for decision-making. Do NOT use when reviewing the graph for weak spots — you need to see low-confidence points to identify what needs verification.
