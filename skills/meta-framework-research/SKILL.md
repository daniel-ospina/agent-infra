---
name: meta-framework-research
description: "Use when asked to research a domain's ontology, taxonomy, and methodology hierarchy — any domain. Produces a structured meta-framework document with thinkers, frameworks, tensions, and gaps. 7-phase pipeline with parallel sub-agent dispatch and fresh-context review gate."
domain: capability
type: Workflow
status: live
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
tags: [research, ontology, meta-framework, domain, pipeline]
summary: "General-purpose domain ontology research skill — 7-phase pipeline encoding the startup-strategy methodology for any domain."
created: 2026-07-11
updated: 2026-07-11
---

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

# Meta-Framework Research

Researches ANY domain's ontology, taxonomy, and conceptual/theoretical/methodology hierarchy into a structured meta-framework document. Encodes the methodology demonstrated for startup strategy: parallel sub-agent dispatch with multiple lenses, domain detection (Cynefin), confidence tagging, and fresh-context review.

## Pipeline

7 sequential phases. Each writes intermediate artifacts to `research/` for state persistence and resume support.

```
Phase 1 (Intake)       → research/01-domain-classification.md
Phase 2 (Reframing)     → research/02-reframed-problem.md
Phase 3 (Parallel)      → research/03-lenses/<lens>.md
Phase 4 (Synthesis)     → research/04-synthesis-map.yaml
Phase 5 (Gap Analysis)  → research/05-gaps.md
Phase 6 (Output)        → meta-framework.md (final)
Phase 7 (Review)        → research/07-review-cycle-N.md
```

**Resume:** Phase start checks for existing artifact → skip if complete.

## Invocation

```
/skill:meta-framework-research domain=<name> [scope=<depth>] [team=<name>] [lenses=<list>] [execution_intent=<profile>]
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `domain` | `string` | ✅ | — | Lowercase, hyphenated. E.g. "startup-strategy", "tax-law" |
| `scope` | `'comprehensive' \| 'targeted' \| 'quick'` | ❌ | `comprehensive` | Research depth |
| `team` | `string` | ❌ | inferred | Team for `docs/teams/<team>/` path |
| `lenses` | `Lens[]` | ❌ | auto | `canonical \| critical \| systems \| historical \| outlier \| practitioner \| contemporary \| authority` |
| `execution_intent` | `'fast' \| 'autonomous' \| 'budget'` | ❌ | `autonomous` | Profile per execution-intent skill |

Lens auto-selection: Complex→all 8 (canonical, critical, systems, historical, outlier, practitioner, contemporary, authority), Complicated→5 (canonical, critical, systems, practitioner, contemporary) [authority optional], Clear→none. execution_intent=fast→3 lenses (canonical, critical, authority).

## Output

`docs/teams/<team>/<domain>/meta-framework.md` with 10 sections:
1. Core Thesis
2. Domain Detection (Cynefin)
3. Thinker Inventory
4. Ontology Tree
5. Framework Catalog
6. Central Tensions
7. Context-Fit Matrices
8. Gaps & Blind Spots
9. Active Debates
10. Key References
11. Recontextualization

All claims confidence-tagged (HIGH | ⚠️ emerging | ⚠️ single-source | ⚠️ hypothesis).

## Phase Sequence

Read workflow files in order. Each phase's file contains full instructions. Skip phases per the skipping table:

| Condition | Skip |
|-----------|------|
| Clear domain | Phase 3 (single best-practice query) |
| Complicated domain | Phase 5 (light checklist) |
| execution_intent=fast | Phase 3: 2 lenses. Phase 5: skip. Phase 7: checklist. |
| execution_intent=budget | Phase 3: skip external, internal substitutes |

## Error Handling

| Phase | Failure | Action |
|-------|---------|--------|
| 1-3 | Complete | Abort, surface diagnostic |
| 3 | ≤1 lens failed | Continue, flag gap in Phase 5 |
| 3 | ≥2 lenses failed | Abort, output partial findings |
| 4-6 | Failure | Retry once, then degraded output with ⚠️ SYNTHESIS_INCOMPLETE |
| 7 | Stall (3 cycles) | Document unresolved, proceed |

---

> Continue following the workflow as mandated by this skill. Do not skip steps.
