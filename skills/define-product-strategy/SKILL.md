---
name: define-product-strategy
description: "Product Strategist role (S1). 7-step process for what to build and in what order. Gap analysis, initiatives, role mapping, workflows plan, coherence review, roadmap."
domain: capability
type: Workflow
subjects.team: organisation-design-team
allowed-tools: read write edit bash grep find web_search web_fetch todo_write task
---

# Define Product Strategy

> ⛔ **This skill MUST be read in full — not skimmed.** Formal review gates depend on its workflow.
> Skipping steps silently bypasses quality checks. Missing gates = undetected breakages.

Produces the Product Strategy artifact and Roadmap. Takes the S4 product vision as input. Operates within constraints set by the Team Strategy (produced by `define-team-strategy`). Executed by the Product Strategist role.

## Philosophy

**Good strategy eliminates options.** It forces hard trade-offs that drive specialization. If the output doesn't make you uncomfortable about what you're NOT doing, it's not a strategy — it's a wishlist.

- Default to less. Doing fewer things well beats doing more things poorly.
- Every "yes" to an initiative is a "no" to something else. Make those nos explicit.
- Delegation is the first choice. Adding roles is the last.
- The best infrastructure is the infrastructure you don't build.

## VSM Alignment

Product Strategist is S1 (domain operations) executing recursive S3 (strategy) within its domain. Team Strategist is S3 at the organizational level.

| S3 Function | Step | Ponytail Check |
|-------------|------|----------------|
| Bridge current to future | 1: Gap analysis | Which gaps should we accept? |
| Balance autonomy with goals | 2: Horizon mapping | What can be deferred? Best infra is unbuilt. |
| Resource allocation | 3: Initiative generation | What's the one-line version? |
| System re-organization | 4-5: Role gap + workflows | Delegate → skills → expand agreement → add role (last) |
| Performance management | 6: Coherence review | What did we say no to? |
| Handoff to execution | 7: Roadmap → Coordinator | — |

## What you are missing

- [x] `workflow/01-gap-analysis.md` — current vs desired, competitor research, internal analytics, AI review
- [x] `workflow/02-horizon-mapping.md` — Three Horizons, ponytail check, human gate
- [x] `workflow/03-initiative-generation.md` — one-off + ongoing Actions, human gate
- [x] `workflow/04-role-gap-analysis.md` — map initiatives to existing roles, AI review
- [x] `workflow/05-workflows-plan.md` — delegate → skills → expand → add, human gate
- [x] `workflow/06-coherence-review.md` — internal consistency, trade-off check
- [x] `workflow/07-roadmap.md` — handoff to Coordinator, human gate

## What fails if you skip

| If you skip... | This breaks... |
|----------------|----------------|
| Gap analysis | Strategy built on assumptions, not data. Competitor threats invisible. |
| Horizon mapping | Everything is urgent. No sequencing. Burnout and thrash. |
| Initiative generation | Vision never becomes action. Strategy is a document, not a plan. |
| Role gap analysis | Initiatives have no owners. Work falls through cracks. |
| Workflows plan | Roles overloaded or under-specified. Coordination overhead explodes. |
| Coherence review | Contradictions between steps. Strategy doesn't hang together. |
| Roadmap | Coordinator has nothing to execute. Strategy stays on the shelf. |
---
> Continue following the workflow as mandated by this skill. Do not skip steps.
