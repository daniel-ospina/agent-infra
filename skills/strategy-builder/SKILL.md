---
name: strategy-builder
description: Build and evolve go-to-market strategy from frameworks through JTBD to pitch components — produces strategy.md, philosophy.md, experiments, earned secrets
domain: capability
type: Workflow
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---
> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

## Research Discipline

> **Ontology:** `tortoise/docs/ONTOLOGY.md` (v3.1, canonical) — fetch: `gh api repos/daniel-ospina/tortoise/contents/docs/ONTOLOGY.md --jq .content | base64 -d` (§5 = controlled vocabulary).

This skill follows the [research-protocol](../reference/research-protocol/SKILL.md). Tier 3 integration (protocol sits beside — existing adversarial review protocol stays; protocol adds domain detection + Estuarine Mapping).

**Protocol additions:**
- **Domain detection at Phase 1 start:** Classify the strategy context. Market analysis in known categories = Complicated. New market entry = Complex.
- **Estuarine Mapping trigger for complex market analysis:** In Phases 2 (Customer Definition) and 3.5 (Competitor Intelligence), for Complex domains, add constraint-and-constructor mapping: "What are the market constraints? Which can we change? Where are the energy gradients?"
- **Distributed sensing for Complex:** Run 2-3 independent market analyses from different lenses before converging on strategy.

**Protocol compliance self-audit:**
```
☐ Domain classified at Phase 1 start
☐ Estuarine Mapping applied for Complex market contexts
☐ Distributed sensing run for Complex strategy questions
☐ Adversarial review protocol (Attacker/Defender/Synthesizer) preserved
☐ Research review cycle completed
```

# Strategy Builder

> ⚠️ **This file is an index.** It contains ZERO workflow instructions.
> You have NOT loaded this skill yet. The actual workflow is in the files below.

## What you are missing

- [ ] `workflow/01-mode-and-setup.md` — mode selection (full build vs incremental), setup
- [ ] `workflow/02-full-build-frameworks.md` — strategy frameworks analysis
- [ ] `workflow/03-full-build-jtbd.md` — Jobs-to-be-Done mapping
- [ ] `workflow/04-full-build-pitch.md` — pitch component generation
- [ ] `workflow/05-full-build-experiments.md` — experiments + earned secrets
- [ ] `workflow/06-incremental-review.md` — incremental mode review + update cycle

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| All sub-files | No strategy produced. strategy.md not written. GTM direction missing. |
| `workflow/01` | Wrong mode selected. Full build runs when incremental needed. Wasted work. |
| `workflow/02` | Strategy frameworks not analyzed. No competitive positioning. Foundation missing. |
| `workflow/03` | JTBD not mapped. Strategy built without understanding customer jobs. |
| `workflow/04` | Pitch components missing. Strategy can't be operationalized into outreach. |
| `workflow/05` | No experiments designed. No earned secrets captured. Strategy can't evolve. |
| `workflow/06` | Incremental updates not reviewed. Strategy drifts from reality. |

## Reference (read when directed)

- `references/protocols.md` — framework protocols, JTBD patterns, experiment templates
- `references/context-management.md` — session management, handoff, resumption
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
