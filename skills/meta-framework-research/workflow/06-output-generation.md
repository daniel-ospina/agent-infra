# Phase 6: Output Generation

Write the final meta-framework document. All 10 sections must be populated. All claims confidence-tagged.

## Steps

### 6.1 Read Synthesis Artifacts
Read `research/04-synthesis-map.yaml` and `research/05-gaps.md`.
If synthesis was split (research/04-ontology-tree.md exists), read that too.

### 6.2 Determine Output Path
`docs/teams/<team>/domains (S1)/<domain>/meta-framework.md` (eldato repo layout — the destination repo's docs/teams tree; fetch existing: `gh api repos/daniel-ospina/eldato/contents/<path> --jq .content | base64 -d`)

Create parent directories if needed.

### 6.3 Write Meta-Framework Document

Use this template. Every section must be populated — no placeholder text.

```markdown
---
title: "<Domain> Meta-Framework"
type: meta-framework
domain: <domain-slug>
status: draft
created: <YYYY-MM-DD>
updated: <YYYY-MM-DD>
---

# <Domain> Meta-Framework

## 1. Core Thesis
[1-3 paragraph synthesis of what this domain is fundamentally about]

## 2. Domain Detection
**Cynefin Classification:** <Clear | Complicated | Complex>
**Rationale:** <from Phase 1>

## 3. Thinker Inventory
| Thinker | Type | Core Thesis | Key Works | School |
|---------|------|------------|-----------|--------|
| <name> | <Academic \| Practitioner \| Thought Leader \| Contrarian \| Hybrid> | <thesis> | <works> | <school> |

**Types:** Academic = university-affiliated, peer-reviewed. Practitioner = builds/ships/operates in the domain. Thought Leader = shapes discourse via talks, writing, social media (may not publish academically). Contrarian = explicitly challenges the consensus; says "everything you know about X is wrong." Hybrid = spans multiple types.

### Contrarian Thinkers
Thinkers who explicitly challenge the domain's consensus. They say "the establishment is wrong about X." Each entry must cite WHAT they challenge and WHY.

| Thinker | Challenges | Their Alternative | Evidence | Confidence |
|---------|-----------|-------------------|----------|------------|
| <name> | <consensus view they reject> | <what they propose instead> | <what evidence supports their challenge> | <tier> |

**Source:** Primarily from the outlier lens (Phase 3). The critical lens may also surface contrarian positions.

## 4. Ontology Tree
[domain → sub-domain → methodology as nested list from Phase 4]

## 5. Framework Catalog
| Framework | Sub-Domain | Core Claim | When to Use | When NOT | Confidence |
|-----------|-----------|------------|-------------|----------|------------|

## 6. Central Tensions
| Axis | Position A | Position B |
|------|-----------|------------|

## 7. Context-Fit Matrices
When to use which approach based on context variables. For each sub-domain with ≥2 frameworks, provide a decision matrix:

Default context variables (replace with domain-specific ones when relevant): **Speed** (time-sensitive → lightweight), **Uncertainty** (high → adaptive; low → analytical), **Risk** (reversible → lightweight; irreversible → exhaustive), **Complexity/Stakeholders** (simple → one framework; multi-stakeholder → structured).

```markdown
| Context Variable | Framework A | Framework B | Framework C |
|-----------------|-------------|-------------|-------------|
| Speed            | Fast → A    | Moderate → B | Slow → C    |
| Uncertainty      | Low → A     | Medium → B   | High → C    |
| Risk             | Reversible → A | —         | Irreversible → C |
```

**Rule:** Every framework in the catalog must appear in at least one context-fit matrix. If a framework has ONLY ONE valid context, document it as single-context with rationale.

## 8. Gaps & Blind Spots
[From Phase 5 gap analysis]

## 9. Active Debates
[Open questions where evidence is inconclusive]

## 10. Key References
- [[entity-page-1]]
- [[concept-page-1]]

## 11. Recontextualization
For the top 5-10 frameworks in the catalog, explicitly recontextualize for the current era (2026). This is where frameworks that still hold are updated — not replaced.

### 11.1 Search for Published Recontextualization (REQUIRED)
**Before generating any recontextualization content**, run a web_search for each framework to find published analysis of whether it still holds:

```
web_search("does <framework> still hold in <current year>")
web_search("<framework> recontextualized for AI era")
web_search("<framework> limitations modern context")
```

**Why:** People are already researching "does Porter still hold?" "is Lean Startup dead?" "does Cynefin apply to AI?" — this is published work. Leverage it instead of generating analysis from scratch. Each recontextualization entry should cite at least one external source found via search.

**Fallback:** If no published analysis exists for a framework → that framework gets the ⚠️ hypothesis tag. Agent-generated recontextualization without external corroboration is speculative.

```markdown
| Framework | Original Context | What Holds | What Changed | Recontextualized Application |
|-----------|-----------------|------------|--------------|------------------------------|
| <name>    | <era + conditions it was built for> | <what still applies> | <what AI/automation/cost inversion invalidated> | <how to apply it now> |
```

**Rules:**
- Priority: frameworks with "mainly 1990s" or "pre-digital" temporal bias from Phase 5
- Every entry must cite evidence from the contemporary lens (Phase 3)
- If a framework survived the temporal validity stress test unchanged, say so explicitly: "No recontextualization needed — framework assumes conditions that still hold."
- Flag frameworks where recontextualization is speculative (⚠️ hypothesis — insufficient contemporary evidence)

## Source Confidence Summary
| Claim | Tier | Sources |
|-------|------|---------|

```

### 6.4 Confidence Tagging
Every factual claim must carry a confidence tag:

| Sources | Tag |
|---------|-----|
| 3+ independent | (none — HIGH) |
| 2 sources | ⚠️ emerging |
| 1 source | ⚠️ single-source — verify when new source available |
| 0 sources (inference) | ⚠️ hypothesis — see Required Evidence |

### 6.5 Quality Self-Check
Before proceeding to Phase 7:
- [ ] All 11 sections populated
- [ ] No placeholder text ("TBD", "TODO", "to be populated")
- [ ] Every confidence tag is a valid tier: HIGH (untagged), ⚠️ emerging, ⚠️ single-source, ⚠️ hypothesis — no custom tags (MEDIUM, LOW, etc.)
- [ ] Every framework in catalog has "When NOT" column populated (no blanks)
- [ ] At least one Context-Fit Matrix per sub-domain with ≥2 frameworks
- [ ] Source Confidence Summary table present
- [ ] Every ontology tree leaf has a corresponding Framework Catalog entry (no orphans — missing entries must have a documented exclusion reason)
- [ ] No agent-synthesized or hallucinated entries in catalog — every entry cites a published source or lens research, not agent inference
- [ ] File written to correct path

Proceed to Phase 7.
